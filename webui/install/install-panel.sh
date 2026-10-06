#!/bin/sh
# Update only web assets and the LuCI session bridge; retain router services.
set -eu
BASE_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
[ "$(id -u)" = 0 ] || { echo 'Run as root on OpenWrt.' >&2; exit 1; }
[ -f /etc/openwrt_release ] && [ -f /usr/share/ucode/luci/dispatcher.uc ] || {
    echo 'Requires OpenWrt 24.10 with LuCI.' >&2
    exit 1
}

backup="/root/router-plus-panel-backup-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$backup"
for path in /www/vektort13-admin /www/cgi-bin/vektort13 /usr/share/luci/menu.d/router-plus.json /usr/share/ucode/luci/controller/router_plus.uc; do
    if [ -e "$path" ]; then
        relative="${path#/}"
        mkdir -p "$backup/$(dirname "$relative")"
        cp -a "$path" "$backup/$relative"
    fi
done
chmod -R go-rwx "$backup"

mkdir -p /www/vektort13-admin /www/cgi-bin/vektort13 /usr/share/luci/menu.d /usr/share/ucode/luci/controller
cp "$BASE_DIR"/webui/frontend/* /www/vektort13-admin/
cp "$BASE_DIR"/webui/cgi-bin/*.sh /www/cgi-bin/vektort13/
cp "$BASE_DIR/webui/luci/router-plus.json" /usr/share/luci/menu.d/
cp "$BASE_DIR/webui/luci/router_plus.uc" /usr/share/ucode/luci/controller/
chmod 644 /www/vektort13-admin/* /usr/share/luci/menu.d/router-plus.json /usr/share/ucode/luci/controller/router_plus.uc
chmod 755 /www/vektort13-admin /www/cgi-bin/vektort13 /www/cgi-bin/vektort13/*.sh
rm -f /tmp/luci-indexcache /tmp/luci-indexcache.*.json
/etc/init.d/uhttpd restart
echo "Router Plus panel updated. Private backup: $backup"
echo 'Open /cgi-bin/luci/admin/router_plus?page=pptp'
