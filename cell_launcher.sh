#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cell_launcher.sh — Deploy any spring as a biomeOS cell
#
# A cell is a NUCLEUS + domain overlay + petalTongue live mode, deployed
# as a single biomeOS graph. This is the standard way to "run a spring
# as a desktop app" within ecoPrimals.
#
# Usage:
#   ./tools/cell_launcher.sh <spring> start   — deploy cell via biomeOS
#   ./tools/cell_launcher.sh <spring> stop    — stop the cell
#   ./tools/cell_launcher.sh <spring> status  — check cell health
#   ./tools/cell_launcher.sh list             — show available cells
#
# Springs: hotspring, wetspring, neuralspring, ludospring, airspring,
#          groundspring, healthspring, esotericwebb
#
# Prerequisites:
#   - plasmidBin depot with all primal binaries
#   - X11/Wayland session (petalTongue live mode needs a display)
#   - BEARDOG_FAMILY_SEED env (or will be generated)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLASMIDBIN="$SCRIPT_DIR"
ECO_ROOT="$(cd "$PLASMIDBIN/../.." && pwd)"

CELLS_DIR="$PLASMIDBIN/cells"
FAMILY_ID="${FAMILY_ID:-}"

usage() {
    echo "Usage: $0 <spring|list> [start|stop|status]"
    echo ""
    echo "Available cells:"
    if [ -d "$CELLS_DIR" ]; then
        for f in "$CELLS_DIR"/*_cell.toml; do
            [ -f "$f" ] || continue
            stem=$(basename "$f" _cell.toml)
            echo "  $stem"
        done
    fi
    echo ""
    echo "Options:"
    echo "  --family ID         Override family identity"
    echo "  --plasmidbin PATH   Override plasmidBin location"
    exit 1
}

[ $# -lt 1 ] && usage

# Handle "list" subcommand
if [ "$1" = "list" ]; then
    echo "Available cells:"
    for f in "$CELLS_DIR"/*_cell.toml; do
        [ -f "$f" ] || continue
        stem=$(basename "$f" _cell.toml)
        domain=$(grep 'domain = ' "$f" | head -1 | sed 's/.*= "//;s/"//')
        echo "  $stem  ($domain)"
    done
    exit 0
fi

SPRING="$1"
ACTION="${2:-start}"

# Parse optional flags
shift 2 2>/dev/null || shift 1 2>/dev/null || true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --family) FAMILY_ID="$2"; shift 2 ;;
        --plasmidbin) PLASMIDBIN="$2"; shift 2 ;;
        *) echo "Unknown flag: $1"; usage ;;
    esac
done

CELL_GRAPH="$CELLS_DIR/${SPRING}_cell.toml"

if [ ! -f "$CELL_GRAPH" ]; then
    echo "ERROR: Cell graph not found: $CELL_GRAPH"
    echo ""
    echo "Available cells:"
    for f in "$CELLS_DIR"/*_cell.toml; do
        [ -f "$f" ] || continue
        echo "  $(basename "$f" _cell.toml)"
    done
    exit 1
fi

# Set up identity
if [ -z "$FAMILY_ID" ]; then
    FAMILY_ID="${SPRING}-cell-$(date +%s)"
fi
export FAMILY_ID

if [ -z "${BEARDOG_FAMILY_SEED:-}" ]; then
    export BEARDOG_FAMILY_SEED
    BEARDOG_FAMILY_SEED="$(head -c 32 /dev/urandom | xxd -p)"
fi

SOCKET_DIR="${XDG_RUNTIME_DIR:-/tmp}/biomeos"
mkdir -p "$SOCKET_DIR"
export BIOMEOS_SOCKET_DIR="$SOCKET_DIR"
export ECOPRIMALS_PLASMID_BIN="$PLASMIDBIN"

echo "=========================================="
echo "  Cell: $SPRING"
echo "  Action: $ACTION"
echo "=========================================="
echo "  Graph:      $CELL_GRAPH"
echo "  Family:     $FAMILY_ID"
echo "  plasmidBin: $PLASMIDBIN"
echo "  Sockets:    $SOCKET_DIR"
echo "=========================================="

BIOMEOS_BIN="$PLASMIDBIN/biomeos/biomeos"
[ -x "$BIOMEOS_BIN" ] || BIOMEOS_BIN="$(command -v biomeos 2>/dev/null || true)"

NUCLEUS_LAUNCHER="$PLASMIDBIN/nucleus_launcher.sh"
START_PRIMAL="$PLASMIDBIN/start_primal.sh"

case "$ACTION" in
    start)
        if [ -n "$BIOMEOS_BIN" ] && [ -x "$BIOMEOS_BIN" ]; then
            echo ""
            echo "Deploying via biomeOS..."
            exec "$BIOMEOS_BIN" deploy "$CELL_GRAPH"
        elif [ -x "$NUCLEUS_LAUNCHER" ]; then
            echo ""
            echo "biomeOS binary not found — falling back to nucleus_launcher + overlay"
            echo "Starting NUCLEUS base..."
            "$NUCLEUS_LAUNCHER" --composition full start

            echo ""
            echo "NUCLEUS status:"
            "$NUCLEUS_LAUNCHER" status

            echo ""
            echo "Launching petalTongue in live mode..."
            PT_BIN="$PLASMIDBIN/petaltongue/petaltongue"
            [ -x "$PT_BIN" ] || PT_BIN="$(command -v petaltongue 2>/dev/null || true)"
            if [ -n "$PT_BIN" ] && [ -x "$PT_BIN" ]; then
                exec "$PT_BIN" live --socket "$SOCKET_DIR/petaltongue-${FAMILY_ID}.sock"
            else
                echo "ERROR: petaltongue binary not found"
                exit 1
            fi
        else
            echo "ERROR: Neither biomeOS binary nor nucleus_launcher.sh found"
            echo "  Install plasmidBin or set ECOPRIMALS_PLASMID_BIN"
            exit 1
        fi
        ;;

    stop)
        if [ -x "$NUCLEUS_LAUNCHER" ]; then
            "$NUCLEUS_LAUNCHER" stop
        else
            echo "Stopping primals in $SOCKET_DIR..."
            for sock in "$SOCKET_DIR"/*.sock; do
                [ -S "$sock" ] || continue
                echo "  Sending shutdown to $sock"
                echo '{"jsonrpc":"2.0","method":"lifecycle.shutdown","params":{},"id":1}' | \
                    timeout 2 socat - UNIX-CONNECT:"$sock" 2>/dev/null || true
            done
        fi
        ;;

    status)
        echo ""
        echo "Socket directory: $SOCKET_DIR"
        if [ -d "$SOCKET_DIR" ]; then
            for sock in "$SOCKET_DIR"/*.sock; do
                [ -S "$sock" ] || continue
                name=$(basename "$sock" .sock)
                response=$(echo '{"jsonrpc":"2.0","method":"health.liveness","params":{},"id":1}' | \
                    timeout 2 socat - UNIX-CONNECT:"$sock" 2>/dev/null || echo "UNREACHABLE")
                if echo "$response" | grep -q '"result"'; then
                    echo "  ALIVE  $name"
                else
                    echo "  DOWN   $name"
                fi
            done
        else
            echo "  No socket directory found"
        fi
        ;;

    *)
        echo "Unknown action: $ACTION"
        usage
        ;;
esac
