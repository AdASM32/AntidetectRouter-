#!/bin/bash
set -euo pipefail
for module in ppp_generic ppp_mppe pptp tun nf_conntrack_pptp nf_nat_pptp nft_reject_inet nft_fib_inet nft_masq nft_chain_nat; do
    modprobe "$module"
done
for attempt in {1..20}; do
    container_ip="$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' router-plus 2>/dev/null || true)"
    [[ -n "$container_ip" ]] && break
    sleep 1
done
[[ "$container_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Router container address unavailable.' >&2; exit 1; }
iptables -w -t raw -N ROUTER_PLUS_PPTP 2>/dev/null || true
iptables -w -t raw -C PREROUTING -s "$container_ip" -p tcp --dport 1723 -j ROUTER_PLUS_PPTP 2>/dev/null || \
    iptables -w -t raw -A PREROUTING -s "$container_ip" -p tcp --dport 1723 -j ROUTER_PLUS_PPTP
# CT helper lookup uses the protocol on this rule. A TCP match on a caller's
# jump does not supply the protocol when the helper rule is validated.
iptables -w -t raw -C ROUTER_PLUS_PPTP -p tcp --dport 1723 -j CT --helper pptp 2>/dev/null || \
    iptables -w -t raw -A ROUTER_PLUS_PPTP -p tcp --dport 1723 -j CT --helper pptp
