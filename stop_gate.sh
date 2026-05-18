#!/usr/bin/env bash
# plasmidBin/stop_gate.sh — Stop primal processes on a gate
#
# Usage:
#   ./stop_gate.sh                      # Stop local primals
#   ./stop_gate.sh user@host            # Stop remote primals via SSH
#   ./stop_gate.sh --remote-dir /opt/x  # Custom plasmidBin location

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=ports.env
source "$SCRIPT_DIR/ports.env"

REMOTE_PLASMID_DIR="/opt/plasmidBin"
GATE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --remote-dir) REMOTE_PLASMID_DIR="$2"; shift 2 ;;
        --help)
            echo "Usage: $0 [user@host] [--remote-dir DIR]"
            exit 0
            ;;
        -*) echo "Unknown option: $1"; exit 1 ;;
        *)  GATE="$1"; shift ;;
    esac
done

PRIMAL_NAMES="$ALL_PRIMALS"

do_stop() {
    echo "Stopping primals..."
    for p in $PRIMAL_NAMES; do
        pids=$(pgrep -f "$REMOTE_PLASMID_DIR/primals/$p" 2>/dev/null) || true
        for pid in $pids; do
            kill "$pid" 2>/dev/null || true
            echo "  $p (PID $pid): stopped"
        done
    done
    sleep 1

    still_running=0
    for p in $PRIMAL_NAMES; do
        pids=$(pgrep -f "$REMOTE_PLASMID_DIR/primals/$p" 2>/dev/null) || true
        for pid in $pids; do
            kill -9 "$pid" 2>/dev/null || true
            echo "  $p (PID $pid): force killed"
            still_running=$((still_running + 1))
        done
    done

    echo ""
    if [[ $still_running -eq 0 ]]; then
        echo "All primals stopped."
    else
        echo "$still_running primals required force kill."
    fi

    # Clean up stale sockets left by stopped primals
    stale_cleaned=0
    for sock_dir in "/run/user/$(id -u)/biomeos" "/run/user/$(id -u)/ecoprimals" "/tmp/biomeos"; do
        [[ -d "$sock_dir" ]] || continue
        for sock in "$sock_dir"/*.sock; do
            [[ -e "$sock" ]] || continue
            if ! fuser "$sock" >/dev/null 2>&1; then
                rm -f "$sock"
                stale_cleaned=$((stale_cleaned + 1))
            fi
        done
    done
    if [[ $stale_cleaned -gt 0 ]]; then
        echo "Cleaned $stale_cleaned stale socket(s)."
    fi
}

if [[ -z "$GATE" ]]; then
    do_stop
else
    echo "Stopping primals on $GATE..."
    ssh "$GATE" "$(declare -f do_stop); REMOTE_PLASMID_DIR=$REMOTE_PLASMID_DIR PRIMAL_NAMES='$PRIMAL_NAMES' do_stop"
fi
