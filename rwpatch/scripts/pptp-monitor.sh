#!/bin/sh
. /usr/lib/router-plus/pptp-runtime.sh
autostart_pending=1
last_result=''
while :; do
    (
        mkdir -p "$PPTP_STATE_DIR"
        chmod 700 "$PPTP_STATE_DIR"
        exec 9>"$PPTP_STATE_DIR/lock"
        flock -x -n 9 || exit 0
        if pptp_selected >/dev/null; then
            pptp_reconcile
        fi
    )
    result="$?"
    if [ "$result" != "$last_result" ]; then
        logger -t pptp-plus "Routing reconciliation result: $result"
        last_result="$result"
    fi
    if [ "$autostart_pending" = 1 ] && pptp_dependencies; then
        profile="$(uci -q get router_plus.main.pptp_autostart)"
        if pptp_managed "$profile" && [ "$(uci -q get "network.$profile.auto")" = 1 ]; then
            (
                exec 9>"$PPTP_STATE_DIR/lock"
                flock -x -n 9 || exit 1
                pptp_select "$profile"
            ) && autostart_pending=0
        else
            autostart_pending=0
        fi
    fi
    sleep 2
done
