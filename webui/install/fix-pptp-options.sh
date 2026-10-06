#!/bin/sh
# OpenWrt's PPTP defaults use the old "mppe required,..." spelling, which
# pppd 2.5.1 rejects. Keep mandatory 128-bit stateless MPPE with modern options.
set -eu
[ "$(id -u)" = 0 ] && [ -f /etc/openwrt_release ] || {
    echo 'Run this fix as root inside the OpenWrt router.' >&2
    exit 1
}
options=/etc/ppp/options.pptp
[ -f "$options" ] && [ ! -L "$options" ] || {
    echo 'Expected a regular /etc/ppp/options.pptp file.' >&2
    exit 1
}

check_options() {
    # dryrun parses the real plugin and options without creating a connection.
    pppd dryrun plugin pptp.so pptp_server 192.0.2.10 file "$1" >/dev/null 2>&1
}

if grep -qE '^[[:space:]]*mppe[[:space:]]+required,no40,no56,stateless[[:space:]]*$' "$options"; then
    temporary="$(mktemp /etc/ppp/options.pptp.router-plus.XXXXXX)"
    trap 'rm -f "$temporary"' EXIT
    cp -p "$options" "$temporary"
    awk '
        /^[[:space:]]*mppe[[:space:]]+required,no40,no56,stateless[[:space:]]*$/ {
            print "require-mppe-128"
            print "nomppe-40"
            print "nomppe-stateful"
            next
        }
        { print }
    ' "$options" > "$temporary"
    check_options "$temporary" || {
        echo 'PPP rejected the proposed options. Original options were retained.' >&2
        exit 1
    }
    backup="$(mktemp -d /root/router-plus-ppp-options-backup.XXXXXX)"
    cp -p "$options" "$backup/options.pptp"
    mv "$temporary" "$options"
    trap - EXIT
    echo "PPTP MPPE options updated. Private backup: $backup/options.pptp"
else
    check_options "$options" || {
        echo 'PPP rejected the current custom PPTP options. No changes were made.' >&2
        exit 1
    }
fi
echo 'PPTP options accepted by pppd; required MPPE-128 is retained for the standard defaults.'
