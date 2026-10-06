#!/bin/sh
# Shared PPTP integration. Sourced by CGI, the VPN switcher and iface hotplug.
# The main routing table and the incoming OpenVPN server are never replaced.

PPTP_STATE_DIR="${PPTP_STATE_DIR:-/tmp/router-plus}"
PPTP_ROUTE_TABLE=201

pptp_valid_id() {
    printf '%s\n' "$1" | grep -qE '^pt_[0-9a-f]{6}$'
}

pptp_managed() {
    pptp_valid_id "$1" &&
        [ "$(uci -q get "network.$1.proto")" = pptp ] &&
        [ "$(uci -q get "network.$1.router_plus")" = 1 ]
}

pptp_profiles() {
    local section
    for section in $(uci -q show network | sed -n 's/^network\.\([^.]*\)=interface$/\1/p'); do
        pptp_managed "$section" && printf '%s\n' "$section"
    done
    return 0
}

pptp_selected() {
    local profile
    [ -f "$PPTP_STATE_DIR/pptp-selected" ] || return 1
    profile="$(cat "$PPTP_STATE_DIR/pptp-selected")"
    pptp_managed "$profile" || return 1
    printf '%s\n' "$profile"
}

pptp_status_json() {
    ubus call "network.interface.$1" status 2>/dev/null || printf '{}\n'
}

pptp_device() {
    local status device
    status="$(pptp_status_json "$1")"
    [ "$(jsonfilter -s "$status" -e '@.up')" = true ] || return 1
    device="$(jsonfilter -s "$status" -e '@.l3_device')"
    case "$device" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
    [ "${#device}" -le 15 ] || return 1
    ip -4 addr show dev "$device" 2>/dev/null | grep -q 'inet ' || return 1
    printf '%s\n' "$device"
}

pptp_rw_device() {
    local device
    device="$(uci -q get openvpn.rw.dev || true)"
    [ -n "$device" ] || device=tun0
    case "$device" in
        tun|tap) device="$(uci -q get network.vpn.device || true)"; [ -n "$device" ] || device=tun0 ;;
    esac
    case "$device" in *[!A-Za-z0-9_-]*) return 1 ;; esac
    [ "${#device}" -le 15 ] || return 1
    printf '%s\n' "$device"
}

pptp_dependencies() {
    local command plugin
    for command in uci ubus jsonfilter ip nft fw4 ifup ifdown; do
        command -v "$command" >/dev/null 2>&1 || return 1
    done
    plugin=0
    for command in /usr/lib/pppd/*/pptp.so; do
        [ -f "$command" ] && plugin=1
    done
    [ "$plugin" = 1 ] && [ -c /dev/ppp ] &&
        ubus list network 2>/dev/null | grep -qx network
}

pptp_settings_init() {
    # UCI cannot create a package until its configuration file exists.
    [ -f /etc/config/router_plus ] || touch /etc/config/router_plus || return 1
    chmod 600 /etc/config/router_plus || return 1
    uci set router_plus.main=settings
}

pptp_pin_server() {
    local profile="$1" server address
    server="$(uci -q get "network.$profile.plus_server" || uci -q get "network.$profile.server")"
    case "$server" in
        *[!0-9.]*)
            # Resolve before selecting the tunnel, then let native PPP retries
            # use this address even while tunnel DNS is unavailable.
            address="$(resolveip -4 -t 5 "$server" 2>/dev/null | head -1)"
            [ -n "$address" ] || address="$(uci -q get "network.$profile.server")"
            printf '%s\n' "$address" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || return 1
            uci set "network.$profile.plus_server=$server" || return 1
            uci set "network.$profile.server=$address" || return 1
            uci commit network
            ;;
        *) return 0 ;;
    esac
}

pptp_firewall_sync() {
    local profile existing
    existing="$(uci -q get firewall.router_plus_pptp.name || true)"
    [ -z "$existing" ] || [ "$existing" = pptp_plus ] || return 1
    if [ -n "$existing" ] && [ "$(uci -q get router_plus.main.firewall_managed || true)" != 1 ]; then
        return 1
    fi
    pptp_settings_init || return 1
    uci set firewall.router_plus_pptp=zone || return 1
    uci set firewall.router_plus_pptp.name=pptp_plus
    uci set firewall.router_plus_pptp.input=REJECT
    uci set firewall.router_plus_pptp.output=ACCEPT
    uci set firewall.router_plus_pptp.forward=REJECT
    uci set firewall.router_plus_pptp.masq=1
    uci set firewall.router_plus_pptp.mtu_fix=1
    uci -q delete firewall.router_plus_pptp.network || :
    for profile in $(pptp_profiles); do
        uci add_list "firewall.router_plus_pptp.network=$profile" || return 1
    done
    # The supported RoadWarrior installer names the incoming server zone "vpn".
    uci set firewall.router_plus_pptp_forward=forwarding
    uci set firewall.router_plus_pptp_forward.src=vpn
    uci set firewall.router_plus_pptp_forward.dest=pptp_plus
    uci commit firewall || return 1
    uci set router_plus.main.firewall_managed=1
    uci commit router_plus
}

pptp_dns_apply() {
    local profile="$1" device="$2" dns servers old_server
    dns="$(uci -q get "network.$profile.plus_dns")"
    [ -n "$dns" ] || dns="$(pptp_status_json "$profile" | jsonfilter -e '@["dns-server"][*]')"
    [ -n "$dns" ] || dns='1.1.1.1 8.8.8.8'
    servers=''
    for old_server in $dns; do
        # DNS values from netifd are addresses; only IPv4 is supported by PPTP mode.
        printf '%s\n' "$old_server" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || continue
        servers="${servers}${servers:+ }${old_server}@${device}"
    done
    [ -n "$servers" ] || return 1
    if [ ! -f "$PPTP_STATE_DIR/dns-before" ]; then
        uci -q get 'dhcp.@dnsmasq[0].server' > "$PPTP_STATE_DIR/dns-before" || :
        uci -q get 'dhcp.@dnsmasq[0].noresolv' > "$PPTP_STATE_DIR/noresolv-before" || :
    fi
    if [ "$(uci -q get 'dhcp.@dnsmasq[0].server')" = "$servers" ] &&
        [ "$(uci -q get 'dhcp.@dnsmasq[0].noresolv')" = 1 ]; then
        return 0
    fi
    uci -q delete 'dhcp.@dnsmasq[0].server' || :
    for old_server in $servers; do
        uci add_list "dhcp.@dnsmasq[0].server=$old_server" || return 1
    done
    uci set 'dhcp.@dnsmasq[0].noresolv=1'
    uci commit dhcp || return 1
    printf '%s\n' "$servers" > "$PPTP_STATE_DIR/dns-owned"
    /etc/init.d/dnsmasq reload
}

pptp_dns_restore() {
    local server original
    [ -f "$PPTP_STATE_DIR/dns-before" ] || return 0
    # Preserve settings changed by the user while PPTP was active.
    if [ "$(uci -q get 'dhcp.@dnsmasq[0].server')" = "$(cat "$PPTP_STATE_DIR/dns-owned" 2>/dev/null)" ] &&
        [ "$(uci -q get 'dhcp.@dnsmasq[0].noresolv')" = 1 ]; then
        uci -q delete 'dhcp.@dnsmasq[0].server' || :
        for server in $(cat "$PPTP_STATE_DIR/dns-before"); do
            uci add_list "dhcp.@dnsmasq[0].server=$server"
        done
        original="$(cat "$PPTP_STATE_DIR/noresolv-before")"
        if [ -n "$original" ]; then
            uci set "dhcp.@dnsmasq[0].noresolv=$original"
        else
            uci -q delete 'dhcp.@dnsmasq[0].noresolv' || :
        fi
        uci commit dhcp
        /etc/init.d/dnsmasq reload
    fi
    rm -f "$PPTP_STATE_DIR/dns-before" "$PPTP_STATE_DIR/dns-owned" "$PPTP_STATE_DIR/noresolv-before"
}

pptp_remove_output_rule() {
    local old
    [ -f "$PPTP_STATE_DIR/pptp-device" ] || return 0
    old="$(cat "$PPTP_STATE_DIR/pptp-device")"
    case "$old" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
    while ip -4 rule del pref 104 oif "$old" lookup "$PPTP_ROUTE_TABLE" 2>/dev/null; do :; done
    ip -4 route del table "$PPTP_ROUTE_TABLE" default dev "$old" metric 10 2>/dev/null || :
    rm -f "$PPTP_STATE_DIR/pptp-device"
}

pptp_guard() {
    local device="${1:-}" rw delete_table='' forward_rules nat_rules='' output_rules
    local profile server helper_definition='' helper_rule=''
    rw="$(pptp_rw_device)" || return 1
    profile="$(pptp_selected || true)"
    if [ -n "$profile" ]; then
        server="$(uci -q get "network.$profile.server")"
        printf '%s\n' "$server" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || return 1
        # fw4 does not automatically attach helpers on a masquerading WAN.
        # The host's Docker NAT helper is in a different network namespace.
        helper_definition='ct helper pptp { type "pptp" protocol tcp; l3proto ip; }'
        helper_rule="ip daddr $server tcp dport 1723 ct helper set \"pptp\";"
    fi
    if [ -n "$device" ]; then
        case "$device" in *[!A-Za-z0-9_-]*) return 1 ;; esac
        forward_rules="iifname \"$rw\" meta nfproto ipv6 drop; iifname \"$rw\" oifname != \"$device\" drop;"
        nat_rules="iifname \"$rw\" oifname \"$device\" meta nfproto ipv4 masquerade;"
        output_rules="oifname != \"lo\" oifname != \"$device\" meta l4proto { tcp, udp } th dport 53 drop;"
    else
        forward_rules="iifname \"$rw\" drop;"
        output_rules='oifname != "lo" meta l4proto { tcp, udp } th dport 53 drop;'
    fi
    nft list table inet router_plus_pptp >/dev/null 2>&1 && delete_table='delete table inet router_plus_pptp'
    # nft applies the replacement atomically. IPv6 is blocked for this IPv4 tunnel.
    nft -f - <<EOF
$delete_table
table inet router_plus_pptp {
    $helper_definition
    chain output { type filter hook output priority -10; policy accept; $helper_rule $output_rules }
    chain forward { type filter hook forward priority -10; policy accept; $forward_rules }
    chain postrouting { type nat hook postrouting priority 100; policy accept; $nat_rules }
}
EOF
}

pptp_reconcile() {
    local profile device rw old
    profile="$(pptp_selected)" || return 1
    rw="$(pptp_rw_device)" || return 1
    # Keep an unreachable route even when the live device disappears: no main-table fallback.
    ip -4 route replace unreachable default table "$PPTP_ROUTE_TABLE" metric 42760 || return 1
    if ! ip -4 rule show | grep -q "^105:.*iif $rw .*lookup $PPTP_ROUTE_TABLE"; then
        ip -4 rule add pref 105 iif "$rw" lookup "$PPTP_ROUTE_TABLE" || return 1
    fi
    device="$(pptp_device "$profile" || true)"
    old="$(cat "$PPTP_STATE_DIR/pptp-device" 2>/dev/null || true)"
    if [ -z "$device" ]; then
        pptp_guard || return 1
        pptp_remove_output_rule
        return 0
    fi
    if [ "$old" != "$device" ]; then
        pptp_guard || return 1
        pptp_remove_output_rule
        ip -4 rule add pref 104 oif "$device" lookup "$PPTP_ROUTE_TABLE" || return 1
        printf '%s\n' "$device" > "$PPTP_STATE_DIR/pptp-device"
    fi
    ip -4 route replace table "$PPTP_ROUTE_TABLE" default dev "$device" metric 10 || return 1
    pptp_dns_apply "$profile" "$device" || return 1
    pptp_guard "$device"
}

pptp_unselect() {
    local profile rw
    profile="$(pptp_selected || true)"
    [ -n "$profile" ] || return 0
    # Keep the guard until the tunnel and our policy rules are removed.
    pptp_guard || return 1
    ifdown "$profile" || return 1
    rw="$(pptp_rw_device)" || return 1
    pptp_remove_output_rule || return 1
    while ip -4 rule del pref 105 iif "$rw" lookup "$PPTP_ROUTE_TABLE" 2>/dev/null; do :; done
    ip -4 route del unreachable default table "$PPTP_ROUTE_TABLE" metric 42760 2>/dev/null || :
    pptp_dns_restore
    rm -f "$PPTP_STATE_DIR/pptp-selected"
    nft delete table inet router_plus_pptp
}

pptp_stop_openvpn_client() {
    local section="$1" config pid attempt
    [ "$section" != rw ] || return 0
    case "$section" in ''|*[!A-Za-z0-9_-]*) return 0 ;; esac
    config="$(uci -q get "openvpn.$section.config" || true)"
    if [ "$(uci -q get "openvpn.$section.client" || true)" != 1 ]; then
        [ -f "$config" ] && grep -qE '^[[:space:]]*(client|tls-client)([[:space:]]|$)' "$config" || return 0
    fi
    /etc/init.d/openvpn stop "$section" >/dev/null 2>&1 || :
    # The original web panel launches clients directly, outside procd.
    pid="$(cat "/var/run/openvpn-$section.pid" 2>/dev/null || true)"
    case "$pid" in ''|*[!0-9]*) return 0 ;; esac
    [ "$(cat "/proc/$pid/comm" 2>/dev/null)" = openvpn ] || return 0
    tr '\000' '\n' < "/proc/$pid/cmdline" | grep -Fxq -- "$config" || return 0
    kill -TERM "$pid" 2>/dev/null || return 0
    for attempt in 1 2 3; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done
    if [ "$(cat "/proc/$pid/comm" 2>/dev/null)" = openvpn ]; then
        tr '\000' '\n' < "/proc/$pid/cmdline" | grep -Fxq -- "$config" && kill -KILL "$pid" 2>/dev/null || :
    fi
    rm -f "/var/run/openvpn-$section.pid"
}

pptp_select() {
    local profile="$1" other
    pptp_managed "$profile" && pptp_dependencies || return 1
    pptp_pin_server "$profile" || return 1
    mkdir -p "$PPTP_STATE_DIR"
    chmod 700 "$PPTP_STATE_DIR"
    [ "$(pptp_selected || true)" = "$profile" ] || pptp_unselect || return 1
    printf '%s\n' "$profile" > "$PPTP_STATE_DIR/pptp-selected"
    # Establish fail-closed routing before switching off other upstreams.
    pptp_reconcile || { pptp_unselect; return 1; }
    for other in $(pptp_profiles); do
        [ "$other" = "$profile" ] || ifdown "$other"
    done
    /etc/init.d/passwall stop >/dev/null 2>&1 || :
    /etc/init.d/passwall2 stop >/dev/null 2>&1 || :
    for other in $(uci -q show openvpn | sed -n 's/^openvpn\.\([^.]*\)=openvpn$/\1/p'); do
        pptp_stop_openvpn_client "$other"
    done
    killall vpn-dns-monitor.sh 2>/dev/null || :
    # Legacy Passwall mode can stop fw4; reload also clears its old kill switch.
    fw4 reload >/dev/null 2>&1 ||
        fw4 start >/dev/null 2>&1 || { pptp_unselect; return 1; }
    ifup "$profile" || { pptp_unselect; return 1; }
}
