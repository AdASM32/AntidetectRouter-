#!/bin/bash
# Explicit deployment on a Ubuntu host; keep host networking and SSH intact.
set -euo pipefail
source /etc/os-release
[[ "$ID" = ubuntu && "$VERSION_ID" = 24.04 ]] || { echo 'Requires Ubuntu 24.04.' >&2; exit 1; }
[[ "$EUID" = 0 ]] || { echo 'Run as root.' >&2; exit 1; }
[[ -n "${SERVER_ADDRESS:-}" ]] || { echo 'Set SERVER_ADDRESS to the public server address.' >&2; exit 1; }
project_dir="$(cd -- "$(dirname -- "$0")/.." && pwd)"
command -v docker >/dev/null || {
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io
}
command -v iptables >/dev/null || {
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y iptables
}
systemctl enable --now docker
for module in ppp_generic ppp_mppe pptp tun nf_conntrack_pptp nf_nat_pptp; do
    modprobe "$module" || { echo "Missing kernel module: $module. Inspect the prerequisites report." >&2; exit 1; }
done
[[ -c /dev/ppp && -c /dev/net/tun ]] || { echo 'The host did not provide PPP/TUN devices.' >&2; exit 1; }
for path in /etc/modules-load.d/router-plus.conf /etc/systemd/system/router-plus-pptp-host.service /usr/local/lib/router-plus/ensure-host.sh; do
    [[ ! -e "$path" ]] || { echo "Existing deployment file: $path. Preserve it before deploying." >&2; exit 1; }
done
if iptables -w -t raw -S ROUTER_PLUS_PPTP >/dev/null 2>&1; then
    echo 'The Router Plus helper chain already exists. Preserve the existing installation.' >&2
    exit 1
fi
if docker container inspect router-plus >/dev/null 2>&1; then
    echo 'The router-plus container already exists. Preserve it and use the documented update workflow.' >&2
    exit 1
fi
if ss -lnu | awk '{print $4}' | grep -qE ':1194$' || ss -lnt | awk '{print $4}' | grep -qE ':8080$'; then
    echo 'Port 1194 or 8080 is in use. Choose ports before deploying.' >&2
    exit 1
fi
for volume in router-plus-etc router-plus-root; do
    if docker volume inspect "$volume" >/dev/null 2>&1; then
        echo "Volume $volume already exists; preserve its configuration before redeploying." >&2
        exit 1
    fi
done
DOCKER_BUILDKIT=0 docker build --file "$project_dir/deployment/Dockerfile" --tag router-plus:local "$project_dir"
docker volume create router-plus-etc >/dev/null
docker volume create router-plus-root >/dev/null
docker run -d --name router-plus --label router-plus.production=true \
    --restart unless-stopped --cap-add NET_ADMIN \
    --device /dev/ppp --device /dev/net/tun \
    --sysctl net.ipv4.ip_forward=1 \
    --publish 127.0.0.1:8080:80 --publish 1194:1194/udp \
    --mount type=volume,src=router-plus-etc,dst=/etc \
    --mount type=volume,src=router-plus-root,dst=/root \
    --env "SERVER_ADDRESS=$SERVER_ADDRESS" router-plus:local

# Reload host modules before Docker at boot, then assign the NAT helper only
# to this container. Host routes and automatic conntrack helpers are unchanged.
printf '%s\n' ppp_generic ppp_mppe pptp tun nf_conntrack_pptp nf_nat_pptp > /etc/modules-load.d/router-plus.conf
install -D -m 0755 "$project_dir/deployment/ensure-host.sh" /usr/local/lib/router-plus/ensure-host.sh
cat > /etc/systemd/system/router-plus-pptp-host.service <<'EOF'
[Unit]
Description=PPTP NAT helper for the Router Plus container
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/lib/router-plus/ensure-host.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now router-plus-pptp-host.service
echo 'Deployment requested. Watch: docker logs -f router-plus'
echo 'Use a PuTTY SSH tunnel: local port 8080 -> 127.0.0.1:8080.'
echo 'PPTP availability must still be tested through a real connection.'
