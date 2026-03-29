#!/usr/bin/env bash
# plasmidBin/start_primal.sh — Unified primal startup wrapper
#
# Absorbs per-primal CLI differences so deploy scripts don't need
# per-primal case blocks. Maps generic intent to primal-specific flags.
#
# Usage:
#   ./start_primal.sh beardog --tcp-port 9100 --socket /tmp/beardog.sock --family-id abc123
#   ./start_primal.sh songbird --tcp-port 9200 --socket /tmp/songbird.sock --dark-forest
#   ./start_primal.sh toadstool --capabilities-only
#
# Generic flags (mapped to per-primal equivalents):
#   --tcp-port PORT      Bind TCP on this port (0.0.0.0)
#   --tcp-bind ADDR      TCP bind address (default: 0.0.0.0)
#   --socket PATH        Unix domain socket path
#   --family-id ID       Family identifier
#   --abstract           Use abstract socket (Android/SELinux)
#   --dark-forest        Enable Dark Forest beacon mode
#   --beardog-socket P   BearDog socket for songbird/other primals
#   --foreground         Run in foreground (default: background with nohup)
#   --capabilities-only  Print capabilities and exit (toadstool)
#   --log-file PATH      Log file (default: /tmp/{primal}.log)
#
# This script encapsulates the CLI audit findings:
#   beardog:   --listen addr:port, --socket, --family-id, --abstract
#   songbird:  --port PORT, --socket, --listen (TCP IPC alt), --beardog-socket
#   squirrel:  --port PORT, --bind ADDR, --socket
#   toadstool: --port PORT, --socket, --family-id
#   nestgate:  --socket-only, --dev (flags inferred; --help segfaults)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PRIMAL=""
TCP_PORT=""
TCP_BIND="0.0.0.0"
SOCKET_PATH=""
FAMILY_ID="${FAMILY_ID:-}"
NODE_ID="${NODE_ID:-}"
ABSTRACT=false
DARK_FOREST=false
BEARDOG_SOCKET="${BEARDOG_SOCKET:-}"
FOREGROUND=false
CAPABILITIES_ONLY=false
LOG_FILE=""
PRIMAL_BIN=""

usage() {
    echo "Usage: $0 <primal-name> [OPTIONS]"
    echo ""
    echo "Primals: beardog, songbird, nestgate, toadstool, squirrel, biomeos, petaltongue, ludospring,"
    echo "         groundspring, healthspring, neuralspring, wetspring, primalspring"
    echo ""
    echo "Generic options (mapped to per-primal CLI):"
    echo "  --tcp-port PORT        TCP port"
    echo "  --tcp-bind ADDR        TCP bind address (default: 0.0.0.0)"
    echo "  --socket PATH          Unix domain socket"
    echo "  --family-id ID         Family ID"
    echo "  --abstract             Abstract socket (Android)"
    echo "  --dark-forest          Dark Forest beacon mode"
    echo "  --beardog-socket PATH  BearDog socket for IPC"
    echo "  --foreground           Run in foreground"
    echo "  --capabilities-only    Print capabilities and exit"
    echo "  --log-file PATH        Log file (default: /tmp/<primal>.log)"
    echo "  --bin PATH             Override binary path"
    echo "  --help                 Show this help"
}

if [[ $# -lt 1 ]]; then
    usage
    exit 1
fi

PRIMAL="$1"
shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tcp-port)          TCP_PORT="$2"; shift 2 ;;
        --tcp-bind)          TCP_BIND="$2"; shift 2 ;;
        --socket)            SOCKET_PATH="$2"; shift 2 ;;
        --family-id)         FAMILY_ID="$2"; shift 2 ;;
        --abstract)          ABSTRACT=true; shift ;;
        --dark-forest)       DARK_FOREST=true; shift ;;
        --beardog-socket)    BEARDOG_SOCKET="$2"; shift 2 ;;
        --foreground)        FOREGROUND=true; shift ;;
        --capabilities-only) CAPABILITIES_ONLY=true; shift ;;
        --log-file)          LOG_FILE="$2"; shift 2 ;;
        --bin)               PRIMAL_BIN="$2"; shift 2 ;;
        --help)              usage; exit 0 ;;
        -*)                  echo "Unknown option: $1"; usage; exit 1 ;;
        *)                   echo "Unknown argument: $1"; usage; exit 1 ;;
    esac
done

# ── Resolve binary path ─────────────────────────────────────────────────────
# plasmidBin layout: <dir>/<binary>; infra layout: primals/<name>. Try both.

if [[ -z "$PRIMAL_BIN" ]]; then
    ARCH=$(uname -m)
    candidate=""

    resolve_spring_path() {
        case "$1" in
            healthspring|healthspring_primal)
                echo "$SCRIPT_DIR/healthspring/healthspring_primal"
                ;;
            primalspring|primalspring_primal)
                echo "$SCRIPT_DIR/primalspring/primalspring_primal"
                ;;
            ludospring)
                echo "$SCRIPT_DIR/ludospring/ludospring"
                ;;
            groundspring)
                echo "$SCRIPT_DIR/groundspring/groundspring"
                ;;
            neuralspring)
                echo "$SCRIPT_DIR/neuralspring/neuralspring"
                ;;
            wetspring)
                echo "$SCRIPT_DIR/wetspring/wetspring"
                ;;
            *)
                echo ""
                ;;
        esac
    }

    candidate=$(resolve_spring_path "$PRIMAL")

    if [[ -n "$candidate" ]] && [[ -f "$candidate" ]]; then
        PRIMAL_BIN="$candidate"
    elif [[ "$ARCH" == "aarch64" ]] && [[ -f "$SCRIPT_DIR/primals/aarch64/$PRIMAL" ]]; then
        PRIMAL_BIN="$SCRIPT_DIR/primals/aarch64/$PRIMAL"
    elif [[ -f "$SCRIPT_DIR/primals/$PRIMAL" ]]; then
        PRIMAL_BIN="$SCRIPT_DIR/primals/$PRIMAL"
    elif [[ -f "$SCRIPT_DIR/$PRIMAL/$PRIMAL" ]]; then
        PRIMAL_BIN="$SCRIPT_DIR/$PRIMAL/$PRIMAL"
    else
        echo "ERROR: Binary not found for $PRIMAL"
        echo "  Checked: $SCRIPT_DIR/$PRIMAL/$PRIMAL"
        echo "  Checked: $SCRIPT_DIR/primals/$PRIMAL"
        sp=$(resolve_spring_path "$PRIMAL")
        [[ -n "$sp" ]] && echo "  Checked: $sp"
        [[ "$ARCH" == "aarch64" ]] && echo "  Checked: $SCRIPT_DIR/primals/aarch64/$PRIMAL"
        exit 1
    fi
fi

if [[ ! -x "$PRIMAL_BIN" ]]; then
    echo "ERROR: $PRIMAL_BIN is not executable"
    exit 1
fi

[[ -z "$LOG_FILE" ]] && LOG_FILE="/tmp/${PRIMAL}.log"

# ── Set environment variables ────────────────────────────────────────────────

[[ -n "$FAMILY_ID" ]] && export FAMILY_ID
[[ -n "$NODE_ID" ]] && export NODE_ID

if $DARK_FOREST; then
    export SONGBIRD_DARK_FOREST=true
    export SONGBIRD_AUTO_DISCOVERY=true
fi

# ── Build per-primal argument list ───────────────────────────────────────────
#
# This is the CLI audit map. Each primal gets its own translation from
# generic flags to primal-specific flags. When primals standardize their
# CLIs, this section shrinks to a single generic case.

ARGS=()

case "$PRIMAL" in
    beardog)
        ARGS+=(server)
        if $ABSTRACT; then
            ARGS+=(--abstract)
        elif [[ -n "$SOCKET_PATH" ]]; then
            ARGS+=(--socket "$SOCKET_PATH")
        fi
        [[ -n "$FAMILY_ID" ]] && ARGS+=(--family-id "$FAMILY_ID")
        [[ -n "$TCP_PORT" ]] && ARGS+=(--listen "$TCP_BIND:$TCP_PORT")
        ;;

    songbird)
        ARGS+=(server)
        [[ -n "$TCP_PORT" ]] && ARGS+=(--port "$TCP_PORT")
        [[ -n "$SOCKET_PATH" ]] && ARGS+=(--socket "$SOCKET_PATH")
        if [[ -n "$BEARDOG_SOCKET" ]]; then
            export BEARDOG_SOCKET
            export BEARDOG_MODE=direct
            export SONGBIRD_SECURITY_PROVIDER=beardog
        fi
        ;;

    squirrel)
        ARGS+=(server)
        [[ -n "$TCP_PORT" ]] && ARGS+=(--port "$TCP_PORT" --bind "$TCP_BIND")
        [[ -n "$SOCKET_PATH" ]] && ARGS+=(--socket "$SOCKET_PATH")
        export SQUIRREL_MODE=server
        ;;

    toadstool)
        if $CAPABILITIES_ONLY; then
            "$PRIMAL_BIN" capabilities 2>/dev/null | head -10 || echo "(capabilities unavailable)"
            exit 0
        fi
        ARGS+=(server)
        [[ -n "$TCP_PORT" ]] && ARGS+=(--port "$TCP_PORT")
        [[ -n "$SOCKET_PATH" ]] && ARGS+=(--socket "$SOCKET_PATH")
        [[ -n "$FAMILY_ID" ]] && ARGS+=(--family-id "$FAMILY_ID")
        export TOADSTOOL_SECURITY_WARNING_ACKNOWLEDGED=1
        [[ -n "$FAMILY_ID" ]] && export TOADSTOOL_FAMILY_ID="$FAMILY_ID"
        [[ -n "$NODE_ID" ]] && export TOADSTOOL_NODE_ID="$NODE_ID"
        ;;

    nestgate)
        # NestGate's --help segfaults. These flags are inferred from docs
        # and binary strings. Update when NestGate CLI is fixed.
        ARGS+=(daemon --socket-only --dev)
        [[ -n "$FAMILY_ID" ]] && export NESTGATE_FAMILY_ID="$FAMILY_ID"
        if [[ -n "$FAMILY_ID" ]]; then
            export NESTGATE_JWT_SECRET="plasmidbin-${NODE_ID:-gate}-$FAMILY_ID"
        fi
        ;;

    biomeos)
        # biomeOS has multiple modes. For composition testing, use `api`
        # (HTTP+WebSocket+UDS) which supports BIOMEOS_PORT env override.
        # For graph orchestration, use `neural-api`.
        ARGS+=(api)
        [[ -n "$TCP_PORT" ]] && ARGS+=(--port "$TCP_PORT")
        [[ -n "$SOCKET_PATH" ]] && ARGS+=(--socket "$SOCKET_PATH")
        [[ -n "$FAMILY_ID" ]] && export FAMILY_ID
        export BIOMEOS_PORT="${TCP_PORT:-${BIOMEOS_PORT:-9800}}"
        ;;

    petaltongue)
        # petalTongue `web` serves HTTP (with --bind), `server` is UDS-only.
        # For composition testing, prefer `web` with TCP.
        if [[ -n "$TCP_PORT" ]]; then
            ARGS+=(web --bind "$TCP_BIND:$TCP_PORT")
        else
            ARGS+=(server)
        fi
        ;;

    ludospring)
        # ludoSpring `server` starts the IPC server. No CLI port flag yet;
        # uses LUDOSPRING_PORT env for TCP binding.
        ARGS+=(server)
        [[ -n "$TCP_PORT" ]] && export LUDOSPRING_PORT="$TCP_PORT"
        ;;

    groundspring)
        ARGS+=(server)
        [[ -n "$TCP_PORT" ]] && export GROUNDSPRING_PORT="$TCP_PORT"
        ;;

    healthspring|healthspring_primal)
        ARGS+=(server)
        [[ -n "$TCP_PORT" ]] && export HEALTHSPRING_PORT="$TCP_PORT"
        ;;

    neuralspring)
        ARGS+=(server)
        [[ -n "$TCP_PORT" ]] && export NEURALSPRING_PORT="$TCP_PORT"
        ;;

    wetspring)
        ARGS+=(server)
        [[ -n "$TCP_PORT" ]] && export WETSPRING_PORT="$TCP_PORT"
        ;;

    primalspring|primalspring_primal)
        ARGS+=(server)
        [[ -n "$TCP_PORT" ]] && export PRIMALSPRING_PORT="$TCP_PORT"
        ;;

    *)
        echo "WARNING: Unknown primal: $PRIMAL — attempting generic start"
        echo "  Trying: $PRIMAL_BIN server ${ARGS[*]:-}"
        ARGS+=(server)
        [[ -n "$TCP_PORT" ]] && export "${PRIMAL^^}_PORT=$TCP_PORT"
        ;;
esac

# ── Launch ───────────────────────────────────────────────────────────────────

echo "start_primal: $PRIMAL"
echo "  binary: $PRIMAL_BIN"
echo "  args:   ${ARGS[*]}"
echo "  log:    $LOG_FILE"
[[ -n "$FAMILY_ID" ]] && echo "  family: $FAMILY_ID"
[[ -n "$TCP_PORT" ]] && echo "  tcp:    $TCP_BIND:$TCP_PORT"
[[ -n "$SOCKET_PATH" ]] && echo "  socket: $SOCKET_PATH"
$DARK_FOREST && echo "  dark_forest: true"
$ABSTRACT && echo "  abstract: true"

if $FOREGROUND; then
    exec "$PRIMAL_BIN" "${ARGS[@]}"
else
    nohup "$PRIMAL_BIN" "${ARGS[@]}" > "$LOG_FILE" 2>&1 &
    PID=$!
    echo "  pid:    $PID"

    sleep 2
    if kill -0 "$PID" 2>/dev/null; then
        echo "  status: running"
    else
        echo "  status: FAILED (check $LOG_FILE)"
        tail -5 "$LOG_FILE" 2>/dev/null || true
        exit 1
    fi
fi
