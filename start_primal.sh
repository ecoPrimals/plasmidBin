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
# Post-convergence (Wave 47): all 13 primals accept --socket and server
# subcommand per DEPLOYMENT_BEHAVIOR_STANDARD. Remaining per-primal blocks
# handle: non-standard TCP flags, env plumbing, and dual-mode primals.

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
    echo "Primals: beardog, songbird, toadstool, barracuda, coralreef, nestgate,"
    echo "         rhizocrypt, loamspine, sweetgrass, biomeos, squirrel, petaltongue,"
    echo "         skunkbat, ludospring"
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

if [[ -z "$PRIMAL_BIN" ]]; then
    ARCH=$(uname -m)
    if [[ "$ARCH" == "aarch64" && -f "$SCRIPT_DIR/primals/aarch64/$PRIMAL" ]]; then
        PRIMAL_BIN="$SCRIPT_DIR/primals/aarch64/$PRIMAL"
    elif [[ -f "$SCRIPT_DIR/primals/$PRIMAL" ]]; then
        PRIMAL_BIN="$SCRIPT_DIR/primals/$PRIMAL"
    elif [[ -f "$SCRIPT_DIR/$PRIMAL/$PRIMAL" ]]; then
        PRIMAL_BIN="$SCRIPT_DIR/$PRIMAL/$PRIMAL"
    elif [[ -f "$SCRIPT_DIR/primals/x86_64-unknown-linux-musl/$PRIMAL" ]]; then
        PRIMAL_BIN="$SCRIPT_DIR/primals/x86_64-unknown-linux-musl/$PRIMAL"
    else
        echo "ERROR: Binary not found for $PRIMAL"
        echo "  Checked: $SCRIPT_DIR/primals/$PRIMAL"
        echo "  Checked: $SCRIPT_DIR/$PRIMAL/$PRIMAL"
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
# Post-convergence: all primals accept `server --socket --port`. Per-primal
# blocks only remain for env plumbing, non-standard TCP flags, or dual modes.

ARGS=()

add_standard_flags() {
    [[ -n "$SOCKET_PATH" ]] && ARGS+=(--socket "$SOCKET_PATH")
    [[ -n "$TCP_PORT" ]]    && ARGS+=(--port "$TCP_PORT")
}

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
        add_standard_flags
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
        add_standard_flags
        [[ -n "$FAMILY_ID" ]] && ARGS+=(--family-id "$FAMILY_ID")
        export TOADSTOOL_SECURITY_WARNING_ACKNOWLEDGED=1
        [[ -n "$FAMILY_ID" ]] && export TOADSTOOL_FAMILY_ID="$FAMILY_ID"
        [[ -n "$NODE_ID" ]] && export TOADSTOOL_NODE_ID="$NODE_ID"
        ;;

    nestgate)
        ARGS+=(server --socket-only)
        [[ -n "$FAMILY_ID" ]] && ARGS+=(--family-id "$FAMILY_ID")
        [[ -n "$TCP_PORT" ]] && ARGS+=(--port "$TCP_PORT")
        [[ -n "$FAMILY_ID" ]] && export NESTGATE_FAMILY_ID="$FAMILY_ID"
        if [[ -n "$FAMILY_ID" ]]; then
            export NESTGATE_JWT_SECRET="plasmidbin-${NODE_ID:-gate}-$FAMILY_ID"
        fi
        ;;

    biomeos)
        ARGS+=(api)
        add_standard_flags
        [[ -n "$FAMILY_ID" ]] && export FAMILY_ID
        export BIOMEOS_PORT="${TCP_PORT:-${BIOMEOS_PORT:-9800}}"
        ;;

    petaltongue)
        if [[ -n "$TCP_PORT" && -z "$SOCKET_PATH" ]]; then
            ARGS+=(web --bind "$TCP_BIND:$TCP_PORT")
        else
            ARGS+=(server)
            add_standard_flags
        fi
        ;;

    ludospring)
        ARGS+=(server)
        [[ -n "$SOCKET_PATH" ]] && ARGS+=(--socket "$SOCKET_PATH")
        [[ -n "$TCP_PORT" ]] && export LUDOSPRING_PORT="$TCP_PORT"
        ;;

    sweetgrass)
        ARGS+=(server)
        add_standard_flags
        ;;

    loamspine)
        ARGS+=(server)
        add_standard_flags
        if [[ -n "$BEARDOG_SOCKET" ]]; then
            export DISCOVERY_ENDPOINT="unix://$BEARDOG_SOCKET"
        elif [[ -n "${SONGBIRD_PORT:-}" ]]; then
            export DISCOVERY_ENDPOINT="tcp://127.0.0.1:${SONGBIRD_PORT}"
        fi
        ;;

    rhizocrypt)
        ARGS+=(server)
        [[ -n "$SOCKET_PATH" ]] && ARGS+=(--unix "$SOCKET_PATH")
        [[ -n "$TCP_PORT" ]] && ARGS+=(--port "$TCP_PORT")
        [[ -n "$FAMILY_ID" ]] && export RHIZOCRYPT_FAMILY_ID="$FAMILY_ID"
        [[ -n "${FAMILY_SEED:-}" ]] && export FAMILY_SEED
        ;;

    barracuda)
        ARGS+=(server)
        [[ -n "$SOCKET_PATH" ]] && ARGS+=(--unix "$SOCKET_PATH")
        [[ -n "$TCP_PORT" ]] && ARGS+=(--port "$TCP_PORT")
        [[ -n "$FAMILY_ID" ]] && export BARRACUDA_FAMILY_ID="$FAMILY_ID"
        ;;

    coralreef)
        ARGS+=(server)
        [[ -n "$TCP_PORT" ]] && ARGS+=(--rpc-bind "$TCP_BIND:$TCP_PORT")
        [[ -n "$FAMILY_ID" ]] && export CORALREEF_FAMILY_ID="$FAMILY_ID"
        ;;

    skunkbat)
        ARGS+=(server)
        [[ -n "$SOCKET_PATH" ]] && ARGS+=(--socket "$SOCKET_PATH")
        [[ -n "$TCP_PORT" ]] && ARGS+=(--port "$TCP_PORT" --bind "$TCP_BIND")
        [[ -n "$FAMILY_ID" ]] && export SKUNKBAT_FAMILY_ID="$FAMILY_ID"
        ;;

    *)
        echo "WARNING: Unknown primal: $PRIMAL — attempting generic start"
        echo "  Trying: $PRIMAL_BIN server --socket/--port"
        ARGS+=(server)
        add_standard_flags
        ;;
esac

# ── Pre-start stale socket cleanup ────────────────────────────────────────────
# Remove any stale socket at the target path before the primal binds.
# Prevents EADDRINUSE from prior crashes. See CAPABILITY_BASED_DISCOVERY_STANDARD §4.

if [[ -n "$SOCKET_PATH" && -S "$SOCKET_PATH" ]]; then
    if command -v fuser >/dev/null 2>&1; then
        if ! fuser "$SOCKET_PATH" >/dev/null 2>&1; then
            rm -f "$SOCKET_PATH"
            echo "start_primal: removed stale socket $SOCKET_PATH"
        fi
    else
        rm -f "$SOCKET_PATH"
        echo "start_primal: removed pre-existing socket $SOCKET_PATH (no fuser to verify)"
    fi
fi

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
