#!/bin/sh
# Read-only prerequisites report; no passwords, routes or OS changes.
set -eu
echo '=== OS and kernel ==='
cat /etc/os-release
uname -r
if command -v systemd-detect-virt >/dev/null; then systemd-detect-virt || true; fi
echo '=== SSH listener ==='
ss -lnt | awk 'NR == 1 || /:22([[:space:]]|$)/'
echo '=== Router capabilities ==='
for module in ppp_generic ppp_mppe pptp tun nf_conntrack_pptp nf_nat_pptp; do
    if modinfo "$module" >/dev/null 2>&1; then
        echo "$module: available"
    else
        echo "$module: unavailable"
    fi
done
for device in /dev/ppp /dev/net/tun /dev/kvm; do
    if [ -c "$device" ]; then echo "$device: present"; else echo "$device: absent"; fi
done
if command -v docker >/dev/null; then docker version --format '{{.Server.Version}}'; else echo 'Docker: not installed'; fi
echo '=== Ports in use ==='
ss -lntu | awk 'NR == 1 || /:1194([[:space:]]|$)|:8080([[:space:]]|$)/'
echo '=== Resources ==='
free -h
df -h /var/lib /root
if command -v python3 >/dev/null; then
    echo '=== PPTP TCP control connection (GRE still needs a tunnel test) ==='
    python3 - <<'PY'
import socket
try:
    with socket.create_connection(("24.47.238.109", 1723), timeout=5):
        print("PPTP TCP 1723: reachable")
except OSError as error:
    print("PPTP TCP 1723:", error)
PY
fi
