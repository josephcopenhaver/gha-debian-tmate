#!/bin/bash

# inspiration from https://github.com/josephcopenhaver/docker-debian-tmate

#
# holy heck, note that output for an incomplete step is not rendered if you failed to open the action run log in time to observe the last print
#
# an active steps' history is NEVER displayed!
#
# ... as a workaround, gonna make this a two script / two phase process to launch and then wait
#
# refs:
# - https://github.com/actions/runner/issues/886
# - https://github.com/actions/runner/issues/2131
# - https://github.com/orgs/community/discussions/44250
#

main() {

    local aptupdated=''

    # ensure utility prereqs are installed
    if ! ( command -v bash >/dev/null 2>/dev/null && command -v xz >/dev/null 2>/dev/null && command -v curl >/dev/null 2>/dev/null && command -v tar >/dev/null 2>/dev/null && command -v gzip >/dev/null 2>/dev/null && command -v nc >/dev/null 2>/dev/null && command -v vim >/dev/null 2>/dev/null && command -v tmux >/dev/null 2>/dev/null ) then
        [ -n "$aptupdated" ] || apt-get update && aptupdated='y'
        
        apt-get install -y \
            bash \
            curl \
            xz-utils \
            tar \
            gzip \
            netcat \
            vim \
            tmux
    fi

    # install open-ssh, locale-gen, screen, and set language to utf8
    # required by: tmate
    if ! ( command -v ssh-keygen >/dev/null 2>/dev/null && command -v locale-gen >/dev/null 2>/dev/null && command -v screen >/dev/null 2>/dev/null && command -v grep >/dev/null 2>/dev/null && command -v awk >/dev/null 2>/dev/null && command -v ps >/dev/null 2>/dev/null && command -v kill >/dev/null 2>/dev/null ) then
        [ -n "$aptupdated" ] || apt-get update && aptupdated='y'

        apt-get install -y \
            openssh-server \
            locales \
            screen \
            grep \
            gawk \
            procps
    fi

    locale-gen

    export LANG='en_US.UTF-8'
    export LANGUAGE='en_US:en'
    export LC_ALL='en_US.UTF-8'

    # install tmate
    export TMATE_VERSION='2.4.0'
    mkdir -p /tmp/tmate/
    curl -fsSL https://github.com/tmate-io/tmate/releases/download/${TMATE_VERSION}/tmate-${TMATE_VERSION}-static-linux-amd64.tar.xz | \
        tar Jxvf - -C /tmp/tmate/ >/dev/null 2>&1
    chmod a+x /tmp/tmate/tmate-${TMATE_VERSION}-static-linux-amd64/tmate
    mv /tmp/tmate/tmate-${TMATE_VERSION}-static-linux-amd64/tmate /usr/local/bin/
    rm -rf /tmp/tmate

    #
    # tmate setup and run
    #

    # setup tmate environment
    export VARDIR='~/.local/var'
    export SOCK="${VARDIR}/tmate/tmate.sock"
    export LOG="${VARDIR}/log/tmate/tmate.log"
    unset VARDIR

    # create user's ssh keys
    test -f ~/.ssh/id_rsa || ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -q -N ""

    # ensure socket directory exists
    mkdir -p "$(dirname "$SOCK")"

    # ensure log file exists
    mkdir -p "$(dirname "$LOG")"
    touch "$LOG"

    # starting ssh agent for tmate session to use
    eval "$(ssh-agent -s)"

    # ensuring there is one user key in the ssh agent for the tmate session to use
    ssh-add ~/.ssh/id_rsa

    # print the tmate version
    tmate -V

    # tmate requires a pseudo terminal
    # and we need to use a script to pipe the ssh connection info
    # back to the docker container logs
    echo "starting" > /tmp/tmate.status
    install /dev/stdin /tmp/start-tmate.sh <<'EOF'

    set -euo pipefail

    export SOCK="$1"
    export LOG="$2"

    (
        set +eo pipefail

        # start a child fork that logs
        # when the tmux server has bootstrapped properly
        # and then terminates
        (
            while :; do
                rw_ssh="$(tmate -S "$SOCK" display -p '#{tmate_ssh}')"
                ro_ssh="$(tmate -S "$SOCK" display -p '#{tmate_ssh_ro}')"

                if [ -n "$rw_ssh" ] && [ -n "$ro_ssh" ]; then
                    echo "[$(date +%s)] RW-SSH CONNECTION: ${rw_ssh}" >> "$LOG"
                    echo "[$(date +%s)] RO-SSH CONNECTION: ${ro_ssh}" >> "$LOG"
                    echo "running" > /tmp/tmate.status
                    break
                fi

                # if parent process has died, means tmate process has died
                if ! kill -0 $$ 2>/dev/null ; then
                    echo "[$(date +%s)] tmate exited: likely failed to start" >> "$LOG"
                    echo "stopped" > /tmp/tmate.status
                    break
                fi

                sleep 1
            done
        ) &

        echo "[$(date +%s)] starting new tmate" >> "$LOG"
        tmate -S "$SOCK" >/dev/null 2>/dev/null || true
        echo "[$(date +%s)] tmate -S done" >> "$LOG"

        # if tmate ever dies, then return from this process
        while :; do
            pid="$(ps a | grep 'tmate -S ' | grep -v grep | awk '{print $1}')"
            if [ -z "$pid" ]; then
                echo "[$(date +%s)] tmate exited" >> "$LOG"
                echo "stopped" > /tmp/tmate.status
                break
            fi
            sleep 5
        done
    )

EOF

    echo "[$(date +%s)] waiting for tmate to start"

    # make tmate start in a pseudo terminal within screen
    # in order for the pseudo terminal to get created you must supply the args
    # -dm for detached mode with screen
    screen -dm \
        bash /tmp/start-tmate.sh "$SOCK" "$LOG"

    # tail -f "$LOG" &

    while :; do
        local status="$(head -1 /tmp/tmate.status)"
        if [[ "$status" == "starting" ]]; then
            sleep 1
            continue
        elif [[ "$status" == "running" ]]; then
            break
        elif [[ "$status" == "stopped" ]]; then
            echo "[$(date +%s)] error: tmate in stopped state"
            exit 1
        fi
        echo "[$(date +%s)] error: tmate in strange state: $status"
        exit 1
    done

    cat "$LOG"
    echo "[$(date +%s)] tmate is running in the background"
}

( set -euo pipefail ; main "$@")
