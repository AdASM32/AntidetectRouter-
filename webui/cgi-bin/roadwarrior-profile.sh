#!/bin/sh
# Download the incoming OpenVPN client profile, separately from upstream configs.
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$SCRIPT_DIR/cgi-common.sh"
require_auth

profile=''
ca="$(uci -q get openvpn.rw.ca || true)"
if [ -f "$ca" ] && command -v openssl >/dev/null; then
    expected="$(openssl x509 -in "$ca" -noout -fingerprint -sha256 2>/dev/null)"
    for candidate in /root/*.ovpn; do
        [ -f "$candidate" ] && [ ! -L "$candidate" ] || continue
        name="$(basename "$candidate" .ovpn)"
        case "$name" in ''|*[!A-Za-z0-9_-]*) continue ;; esac
        grep -qE '^[[:space:]]*client([[:space:]]|$)' "$candidate" || continue
        actual="$(sed -n '/^<ca>$/,/^<\/ca>$/p' "$candidate" | sed '1d;$d' | openssl x509 -noout -fingerprint -sha256 2>/dev/null)"
        [ -n "$expected" ] && [ "$actual" = "$expected" ] || continue
        profile="$candidate"
        break
    done
fi

ACTION="$(get_qs_param action)"
[ -n "$ACTION" ] || ACTION=status
case "$ACTION" in
    status)
        json_headers
        . /usr/share/libubox/jshn.sh
        json_init
        json_add_string status ok
        available=0
        [ -z "$profile" ] || available=1
        json_add_boolean available "$available"
        json_add_string filename "${profile##*/}"
        json_dump
        ;;
    download)
        if [ "${REQUEST_METHOD:-GET}" != GET ]; then
            echo 'Status: 405 Method Not Allowed'
            json_headers
            json_error error 'Use GET to download the client profile'
        elif [ -z "$profile" ]; then
            echo 'Status: 404 Not Found'
            json_headers
            json_error error 'No incoming OpenVPN client profile matching the router CA was found'
        else
            echo 'Content-Type: application/octet-stream'
            printf 'Content-Disposition: attachment; filename="%s"\n' "${profile##*/}"
            echo 'Cache-Control: no-store'
            echo 'X-Content-Type-Options: nosniff'
            echo ''
            cat "$profile"
        fi
        ;;
    *) json_headers; json_error error 'Unknown action' ;;
esac
