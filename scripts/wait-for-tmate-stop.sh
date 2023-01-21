#!/bin/bash

main() {

    export LOG="~/.local/var/log/tmate/tmate.log"

    while :; do
        local status="$(head -1 /tmp/tmate.status)"
        if [[ "$status" == "running" ]]; then
            local pid="$(ps a | grep 'tmate -S ' | grep -v grep | awk '{print $1}')"
            if [ -z "$pid" ]; then
                echo "[$(date +%s)] tmate exit detected: status=$(head -1 /tmp/tmate.status): $(tail -1 "$LOG")"
                exit 0
            fi
            sleep 5
            continue
        elif [[ "$status" == "stopped" ]]; then
            echo "[$(date +%s)] tmate stop detected: $(tail -1 "$LOG")"
            exit 0
        fi
        echo "[$(date +%s)] error: tmate in strange state: $state"
        exit 1
    done
}

( set -euo pipefail ; main "$@")
