#!/bin/sh
# Install the additive PPTP extension from this checkout on OpenWrt.
set -eu
BASE_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
[ "$(id -u)" = 0 ] || { echo 'Run as root on OpenWrt.' >&2; exit 1; }
[ -f /etc/openwrt_release ] && command -v opkg >/dev/null || {
    echo 'This installer requires OpenWrt with opkg (24.10 is supported).' >&2
    exit 1
}
uci -q get openvpn.rw >/dev/null || {
    echo 'Install/configure the existing RoadWarrior OpenVPN server first.' >&2
    exit 1
}
[ "$(uci -q get firewall.vpn.name)" = vpn ] || {
    echo 'Expected the RoadWarrior firewall zone named vpn. Configure it before installing.' >&2
    exit 1
}
if [ "$(uci -q get router_plus.main.installed)" != 1 ]; then
    if ip -4 route show table 201 2>/dev/null | grep -q . ||
        ip -4 rule show | grep -qE '(^104:|^105:|lookup 201([[:space:]]|$))' ||
        grep -qE '^[[:space:]]*201[[:space:]]' /etc/iproute2/rt_tables 2>/dev/null; then
        echo 'Policy table 201 or rule priorities 104/105 are already in use.' >&2
        exit 1
    fi
    if [ -n "$(uci -q get firewall.router_plus_pptp)" ] && [ "$(uci -q get router_plus.main.firewall_managed)" != 1 ]; then
        echo 'The Router Plus firewall section name is already in use.' >&2
        exit 1
    fi
fi

# opkg retains feed signature and package checksum verification.
opkg update
opkg install ppp-mod-pptp ip-full jsonfilter curl uhttpd rpcd luci-app-openvpn openssl-util

# Preserve locally deployed files before the reviewed application update.
backup="/root/router-plus-backup-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$backup"
for path in /www/vektort13-admin /www/cgi-bin/vektort13 /usr/lib/router-plus /etc/init.d/pptp-plus /etc/hotplug.d/iface/95-router-plus-pptp /etc/config/firewall /etc/config/router_plus; do
    if [ -e "$path" ]; then
        relative="${path#/}"
        mkdir -p "$backup/$(dirname "$relative")"
        cp -a "$path" "$backup/$relative"
    fi
done
chmod -R go-rwx "$backup"

sh "$BASE_DIR/webui/install/install-panel.sh"
mkdir -p /usr/lib/router-plus /etc/hotplug.d/iface
cp "$BASE_DIR/rwpatch/scripts/pptp-runtime.sh" /usr/lib/router-plus/
cp "$BASE_DIR/rwpatch/scripts/pptp-monitor.sh" /usr/lib/router-plus/
cp "$BASE_DIR/rwpatch/files/etc/init.d/pptp-plus" /etc/init.d/
cp "$BASE_DIR/rwpatch/files/etc/hotplug.d/iface/95-router-plus-pptp" /etc/hotplug.d/iface/
chmod 755 /usr/lib/router-plus/*.sh /etc/init.d/pptp-plus /etc/hotplug.d/iface/95-router-plus-pptp

# Update canonical legacy monitors only if the existing deployment uses them.
for script in dual-vpn-switcher.sh upstream-monitor.sh; do
    if [ -f "/root/$script" ]; then
        cp "/root/$script" "$backup/$script"
        cp "$BASE_DIR/rwpatch/scripts/$script" "/root/$script"
        chmod 755 "/root/$script"
    fi
done
. /usr/lib/router-plus/pptp-runtime.sh
pptp_firewall_sync
uci set router_plus.main=settings
uci set router_plus.main.installed=1
uci commit router_plus
/etc/init.d/pptp-plus enable
/etc/init.d/pptp-plus restart
fw4 reload || fw4 start
/etc/init.d/uhttpd reload
echo "PPTP extension installed. Existing OpenVPN and Passwall configurations were retained."
echo "Private backup: $backup"
echo 'Open /cgi-bin/luci/admin/router_plus?page=pptp to sign in and open the panel.'
echo 'If legacy VPN monitors were already running, restart them to load their updated code.'
