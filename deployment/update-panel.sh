#!/bin/bash
# Refresh the owned running router's panel without replacing its container.
set -euo pipefail
[[ "$EUID" = 0 ]] || { echo 'Run as root on the Ubuntu host.' >&2; exit 1; }
project_dir="$(cd -- "$(dirname -- "$0")/.." && pwd)"
[[ "$(docker inspect router-plus --format '{{index .Config.Labels "router-plus.production"}}')" = true ]] || {
    echo 'The router-plus container is not labelled as this deployment.' >&2
    exit 1
}
[[ "$(docker inspect router-plus --format '{{.State.Running}}')" = true ]] || {
    echo 'Start the existing router-plus container before updating its panel.' >&2
    exit 1
}

# Retain both the deployed files (install-panel.sh) and the startup source.
backup="$(docker exec router-plus /bin/sh -c '
    set -eu
    backup="/root/router-plus-panel-source-backup-$(date +%Y%m%d-%H%M%S)-$$"
    mkdir -p "$backup"
    cp -a /opt/router-plus/webui "$backup/webui"
    chmod -R go-rwx "$backup"
    printf "%s" "$backup"
')"
docker cp "$project_dir/webui/." router-plus:/opt/router-plus/webui/
docker exec router-plus /bin/sh /opt/router-plus/webui/install/install-panel.sh
echo "Startup source backup inside the router: $backup"
echo 'Open through the SSH tunnel: /cgi-bin/luci/admin/router_plus?page=pptp'
