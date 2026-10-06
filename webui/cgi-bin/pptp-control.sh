#!/bin/sh
# Router Plus PPTP profile API. Mutations require authenticated JSON POSTs.
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$SCRIPT_DIR/cgi-common.sh"
require_auth
json_headers

if [ ! -r /usr/lib/router-plus/pptp-runtime.sh ]; then
    json_error error 'Install the Router Plus PPTP extension first'
    exit 0
fi
. /usr/lib/router-plus/pptp-runtime.sh
. /usr/share/libubox/jshn.sh

reply_error() {
    json_init
    json_add_string status error
    json_add_string message "$1"
    json_dump
    exit 0
}

reply_ok() {
    json_init
    json_add_string status ok
    json_add_string message "$1"
    json_dump
    exit 0
}

single_line() {
    case "$1" in *'
'*) return 1 ;; esac
    [ "${#1}" -le "$2" ] && ! printf '%s' "$1" | grep -q '[[:cntrl:]]'
}

valid_ipv4() {
    local address="$1" octet old_ifs="$IFS"
    case "$address" in ''|*[!0-9.]*) return 1 ;; esac
    IFS=.; set -- $address; IFS="$old_ifs"
    [ "$#" = 4 ] || return 1
    for octet in "$@"; do
        [ -n "$octet" ] && [ "${#octet}" -le 3 ] && [ "$octet" -le 255 ] || return 1
    done
}

valid_server() {
    local label old_ifs="$IFS"
    [ -n "$1" ] && [ "${#1}" -le 253 ] || return 1
    case "$1" in *[!A-Za-z0-9.-]*|.*|*.) return 1 ;; esac
    case "$1" in *[!0-9.]*) ;; *) valid_ipv4 "$1"; return ;; esac
    IFS=.; set -- $1; IFS="$old_ifs"
    for label in "$@"; do
        [ -n "$label" ] && [ "${#label}" -le 63 ] || return 1
        case "$label" in -*|*-) return 1 ;; esac
    done
}

add_profile_json() {
    local profile="$1" status device state up=0 password_set=0
    status="$(pptp_status_json "$profile")"
    state=stopped
    if device="$(pptp_device "$profile")"; then
        state=connected
        up=1
    elif [ "$(jsonfilter -s "$status" -e '@.pending')" = true ]; then
        state=connecting
    elif [ "$(pptp_selected || true)" = "$profile" ]; then
        state=disconnected
    fi
    [ -n "$(uci -q get "network.$profile.password")" ] && password_set=1
    json_add_string id "$profile"
    json_add_string name "$(uci -q get "network.$profile.plus_label")"
    json_add_string server "$(uci -q get "network.$profile.plus_server" || uci -q get "network.$profile.server")"
    json_add_string username "$(uci -q get "network.$profile.username")"
    json_add_string dns "$(uci -q get "network.$profile.plus_dns")"
    json_add_int mtu "$(uci -q get "network.$profile.mtu")"
    json_add_boolean autostart "$(uci -q get "network.$profile.auto")"
    json_add_boolean password_set "$password_set"
    json_add_boolean up "$up"
    json_add_string state "$state"
    json_add_string device "${device:-}"
    json_add_string error "$(jsonfilter -s "$status" -e '@.errors[*].code' | head -1)"
}

ACTION="$(get_qs_param action)"
[ -n "$ACTION" ] || ACTION=list
case "$ACTION" in
    list)
        available=0
        pptp_dependencies && available=1
        json_init
        json_add_string status ok
        json_add_boolean available "$available"
        json_add_string selected "$(pptp_selected || true)"
        json_add_array profiles
        for profile in $(pptp_profiles); do
            json_add_object ''
            add_profile_json "$profile"
            json_close_object
        done
        json_close_array
        json_dump
        exit 0
        ;;
    save|connect|disconnect|delete) ;;
    *) reply_error 'Unknown action' ;;
esac

[ "$REQUEST_METHOD" = POST ] || reply_error 'Use JSON POST for this action'
case "$CONTENT_TYPE" in application/json|application/json\;*) ;; *) reply_error 'Content-Type must be application/json' ;; esac
case "$CONTENT_LENGTH" in ''|*[!0-9]*) reply_error 'Invalid content length' ;; esac
[ "$CONTENT_LENGTH" -ge 2 ] && [ "$CONTENT_LENGTH" -le 16384 ] || reply_error 'Request body is too large or empty'
# A JSON content type prevents cross-origin simple-form submissions; also reject foreign origins.
if [ -n "$HTTP_ORIGIN" ]; then
    case "$HTTP_ORIGIN" in "http://$HTTP_HOST"|"https://$HTTP_HOST") ;; *) reply_error 'Foreign origin is not allowed' ;; esac
fi
read_post_data
json_load "$POST_DATA" || reply_error 'Invalid JSON'
for field in id name server username password dns; do
    json_get_type field_type "$field"
    case "$field_type" in ''|string) ;; *) reply_error "Invalid type for $field" ;; esac
done
json_get_var ID id
if [ -n "$ID" ]; then
    pptp_managed "$ID" || reply_error 'PPTP profile not found'
elif [ "$ACTION" != save ]; then
    reply_error 'Profile ID is required'
fi
mkdir -p "$PPTP_STATE_DIR"
chmod 700 "$PPTP_STATE_DIR"
exec 9>"$PPTP_STATE_DIR/lock"
flock -x -n 9 || reply_error 'PPTP is busy; retry shortly'

case "$ACTION" in
    save)
        json_get_vars name server username password dns mtu autostart
        [ -n "$name" ] && single_line "$name" 64 || reply_error 'Enter a name of up to 64 characters'
        valid_server "$server" || reply_error 'Invalid server IPv4 address or hostname'
        [ -n "$username" ] && single_line "$username" 128 || reply_error 'Invalid username'
        single_line "$password" 256 || reply_error 'Invalid password'
        [ -n "$password" ] || [ -n "$ID" ] || reply_error 'Password is required for a new profile'
        [ -n "$mtu" ] || mtu=1400
        case "$mtu" in *[!0-9]*) reply_error 'Invalid MTU' ;; esac
        [ "$mtu" -ge 576 ] && [ "$mtu" -le 1450 ] || reply_error 'MTU must be between 576 and 1450'
        case "$autostart" in 0|1) ;; *) reply_error 'Invalid autostart value' ;; esac
        single_line "$dns" 128 || reply_error 'Invalid DNS servers'
        for address in $dns; do valid_ipv4 "$address" || reply_error 'DNS servers must be IPv4 addresses separated by spaces'; done
        if [ -z "$ID" ]; then
            ID="pt_$(cut -c1-6 /proc/sys/kernel/random/uuid)"
            pptp_valid_id "$ID" || reply_error 'Could not generate a profile ID'
            uci -q get "network.$ID" >/dev/null && reply_error 'Profile ID collision; retry'
        fi
        pptp_settings_init || reply_error 'Could not initialize Router Plus configuration'
        uci set "network.$ID=interface" || reply_error 'Could not create profile'
        uci set "network.$ID.proto=pptp"
        uci set "network.$ID.router_plus=1"
        uci set "network.$ID.plus_label=$name"
        uci set "network.$ID.server=$server"
        uci set "network.$ID.plus_server=$server"
        uci set "network.$ID.username=$username"
        [ -z "$password" ] || uci set "network.$ID.password=$password"
        uci set "network.$ID.plus_dns=$dns"
        uci set "network.$ID.mtu=$mtu"
        uci set "network.$ID.auto=$autostart"
        uci set "network.$ID.defaultroute=0"
        uci set "network.$ID.peerdns=0"
        uci set "network.$ID.ipv6=0"
        uci set "network.$ID.keepalive=5 5"
        uci set "network.$ID.persist=1"
        uci set "network.$ID.holdoff=5"
        uci set "network.$ID.authfail=1"
        uci commit network || reply_error 'Could not save network configuration'
        chmod 600 /etc/config/network
        uci set router_plus.main=settings
        if [ "$autostart" = 1 ]; then
            for profile in $(pptp_profiles); do
                [ "$profile" = "$ID" ] || uci set "network.$profile.auto=0"
            done
            uci commit network
            uci set "router_plus.main.pptp_autostart=$ID"
        elif [ "$(uci -q get router_plus.main.pptp_autostart)" = "$ID" ]; then
            uci -q delete router_plus.main.pptp_autostart
        fi
        uci commit router_plus
        pptp_firewall_sync || reply_error 'Profile saved, but PPTP firewall configuration failed'
        json_init
        json_add_string status ok
        json_add_string id "$ID"
        json_add_string message 'Profile saved. Reconnect to apply changed settings.'
        json_dump
        ;;
    connect)
        pptp_dependencies || reply_error 'PPTP requires ppp-mod-pptp, /dev/ppp and a running netifd service'
        pptp_select "$ID" || reply_error 'Could not start PPTP; inspect the router logs'
        reply_ok 'Connection requested; wait for the connected status'
        ;;
    disconnect)
        if [ "$(pptp_selected || true)" = "$ID" ]; then
            pptp_unselect || reply_error 'Could not disconnect PPTP safely'
        else
            ifdown "$ID" || reply_error 'Could not disconnect PPTP'
        fi
        reply_ok 'PPTP disconnected'
        ;;
    delete)
        if [ "$(pptp_selected || true)" = "$ID" ]; then
            pptp_unselect || reply_error 'Could not disconnect PPTP safely'
        else
            # netifd may not know a profile that has never been connected.
            ifdown "$ID" >/dev/null 2>&1 || :
        fi
        uci delete "network.$ID" && uci commit network || reply_error 'Could not delete the profile'
        if [ "$(uci -q get router_plus.main.pptp_autostart)" = "$ID" ]; then
            uci -q delete router_plus.main.pptp_autostart
            uci commit router_plus
        fi
        pptp_firewall_sync || reply_error 'Profile deleted, but firewall update failed'
        reply_ok 'Profile deleted'
        ;;
esac
