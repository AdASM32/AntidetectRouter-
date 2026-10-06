#!/bin/sh
# Router services run in the container's network namespace, not on the Ubuntu host.
set -eu
[ -n "${SERVER_ADDRESS:-}" ] || { echo 'SERVER_ADDRESS is required.' >&2; exit 1; }
[ -c /dev/ppp ] && [ -c /dev/net/tun ] || {
    echo 'PPP and TUN devices must be supplied by the host.' >&2
    exit 1
}
mkdir -p /var/run /var/lock /tmp/resolv.conf.d
[ -f /etc/config/network ] || touch /etc/config/network
uci set network.loopback=interface
uci set network.loopback.device=lo
uci set network.loopback.proto=static
uci set network.loopback.ipaddr=127.0.0.1
uci set network.loopback.netmask=255.0.0.0
address="$(ip -4 -o addr show eth0 | awk '{print $4; exit}')"
gateway="$(ip -4 route show default | awk '{print $3; exit}')"
[ -n "$address" ] && [ -n "$gateway" ] || { echo 'Container WAN is not configured.' >&2; exit 1; }
uci set network.wan=interface
uci set network.wan.device=eth0
uci set network.wan.proto=static
uci set "network.wan.ipaddr=$address"
uci set "network.wan.gateway=$gateway"
uci set network.wan.peerdns=0
uci commit network

/sbin/ubusd &
for attempt in 1 2 3 4 5 6 7 8 9 10; do
    ubus list >/dev/null 2>&1 && break
    sleep 1
done
ubus list >/dev/null
/sbin/rpcd &
/sbin/procd -S > /tmp/procd.log 2>&1 &
for attempt in 1 2 3 4 5 6 7 8 9 10; do
    ubus list service 2>/dev/null | grep -qx service && break
    sleep 1
done
ubus list service | grep -qx service || { echo 'procd failed to start.' >&2; exit 1; }
/etc/init.d/network start

if [ ! -f /etc/router-plus-bootstrap-complete ]; then
    # The original installer configures the incoming OpenVPN server. No PPTP
    # credentials are embedded here. Passwall feeds remain an optional step.
    sh /opt/router-plus/roadwarrior-installer.sh <<EOF
eth0
${OPENVPN_PORT:-1194}
client1
10.99.0.0/24
fd42:4242:4242:1::/64
$SERVER_ADDRESS
n
EOF
    uci -q get openvpn.rw >/dev/null || { echo 'OpenVPN setup failed.' >&2; exit 1; }
    touch /etc/router-plus-bootstrap-complete
fi

sh /opt/router-plus/webui/install/install-plus.sh
/etc/init.d/openvpn restart
/etc/init.d/uhttpd restart

for attempt in 1 2 3 4 5 6 7 8 9 10; do
    ip link show tun0 >/dev/null 2>&1 && break
    sleep 1
done
ip link show tun0 >/dev/null 2>&1 || { echo 'OpenVPN server did not create tun0; inspect logread.' >&2; exit 1; }
echo 'Router services started. Sign into LuCI through the SSH tunnel, then configure PPTP.'
echo 'Generated router login is stored privately at /root/roadwarrior-credentials.txt if no password existed.'

stop_router() {
    /etc/init.d/openvpn stop || :
    /etc/init.d/pptp-plus stop || :
    exit 0
}
trap stop_router TERM INT
while :; do sleep 30 & wait "$!"; done
