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
    echo "Primals: beardog, songbird, nestgate, toadstool, squirrel, biomeos, barracuda, coralreef, petaltongue, sweetgrass, rhizocrypt, loamspine, skunkbat, primalspring_primal"
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
# genomeBin layout: primals/{target-triple}/binary
# Falls back to legacy flat layout (primals/binary, primals/aarch64/binary)

detect_target_triple() {
    local machine os kernel
    machine=$(uname -m)
    kernel=$(uname -s | tr '[:upper:]' '[:lower:]')
    case "$kernel" in
        linux)
            case "$machine" in
                x86_64)  echo "x86_64-unknown-linux-musl" ;;
                aarch64) echo "aarch64-unknown-linux-musl" ;;
                armv7l)  echo "armv7-unknown-linux-musleabihf" ;;
                riscv64) echo "riscv64gc-unknown-linux-musl" ;;
                *)       echo "${machine}-unknown-linux-musl" ;;
            esac ;;
        darwin)
            case "$machine" in
                x86_64)  echo "x86_64-apple-darwin" ;;
                arm64)   echo "aarch64-apple-darwin" ;;
                *)       echo "${machine}-apple-darwin" ;;
            esac ;;
        *)  echo "${machine}-unknown-${kernel}" ;;
    esac
}

if [[ -z "$PRIMAL_BIN" ]]; then
    TARGET_TRIPLE=$(detect_target_triple)
    if [[ -f "$SCRIPT_DIR/primals/$TARGET_TRIPLE/$PRIMAL" ]]; then
        PRIMAL_BIN="$SCRIPT_DIR/primals/$TARGET_TRIPLE/$PRIMAL"
    elif [[ -f "$SCRIPT_DIR/primals/$PRIMAL" ]]; then
        PRIMAL_BIN="$SCRIPT_DIR/primals/$PRIMAL"
    else
        echo "ERROR: Binary not found for $PRIMAL"
        echo "  Checked: $SCRIPT_DIR/primals/$TARGET_TRIPLE/$PRIMAL"
        echo "  Checked: $SCRIPT_DIR/primals/$PRIMAL (legacy symlink)"
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
        # BearDog expects NODE_ID + BEARDOG_NODE_ID for identity
        [[ -n "$NODE_ID" ]] && export BEARDOG_NODE_ID="$NODE_ID"
        [[ -z "${NODE_ID:-}" ]] && export NODE_ID="$(hostname -s 2>/dev/null || echo 'gate')"
        [[ -z "${BEARDOG_NODE_ID:-}" ]] && export BEARDOG_NODE_ID="$NODE_ID"
        # BTSP requires FAMILY_SEED env (not just --family-id)
        if [[ -n "$FAMILY_ID" ]] && [[ -z "${BEARDOG_FAMILY_SEED:-}" ]] && [[ -z "${FAMILY_SEED:-}" ]]; then
            export BEARDOG_FAMILY_SEED="plasmidbin-${FAMILY_ID}"
        fi
        ;;

    songbird)
        ARGS+=(server)
        [[ -n "$TCP_PORT" ]] && ARGS+=(--port "$TCP_PORT")
        [[ -n "$SOCKET_PATH" ]] && ARGS+=(--socket "$SOCKET_PATH")
        if [[ -n "$BEARDOG_SOCKET" ]]; then
            ARGS+=(--beardog-socket "$BEARDOG_SOCKET")
            export BEARDOG_SOCKET
            export BEARDOG_MODE=direct
            export SONGBIRD_SECURITY_PROVIDER=beardog
        fi
        ;;

    squirrel)
        ARGS+=(server)
        [[ -n "$TCP_PORT" ]] && ARGS+=(--port "$TCP_PORT")
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
        # Modes: live (native GPU + IPC), server (headless IPC), web (HTTP UI).
        # PETALTONGUE_MODE env selects mode; defaults to server for headless deploys.
        PT_MODE="${PETALTONGUE_MODE:-server}"
        [[ -n "$SOCKET_PATH" ]] && export PETALTONGUE_SOCKET="$SOCKET_PATH"
        case "$PT_MODE" in
            live)
                ARGS+=(live)
                [[ -n "$TCP_PORT" ]] && ARGS+=(--port "$TCP_PORT")
                ;;
            web)
                ARGS+=(web --bind "${TCP_BIND:-0.0.0.0}:${TCP_PORT:-8080}")
                ;;
            *)
                ARGS+=(server)
                ;;
        esac
        ;;

    ludospring)
        # ludoSpring `server` starts the IPC server. No CLI port flag yet;
        # uses LUDOSPRING_PORT env for TCP binding.
        ARGS+=(server)
        [[ -n "$TCP_PORT" ]] && export LUDOSPRING_PORT="$TCP_PORT"
        ;;

    primalspring_primal|primalspring)
        ARGS+=(--mode server)
        [[ -n "$SOCKET_PATH" ]] && ARGS+=(--socket "$SOCKET_PATH")
        [[ -n "$TCP_PORT" ]] && ARGS+=(--port "$TCP_PORT")
        ;;

    barracuda)
        ARGS+=(server)
        [[ -n "$TCP_PORT" ]] && ARGS+=(--port "$TCP_PORT")
        [[ -n "$FAMILY_ID" ]] && export BARRACUDA_FAMILY_ID="$FAMILY_ID"
        ;;

    coralreef)
        ARGS+=(server)
        [[ -n "$SOCKET_PATH" ]] && ARGS+=(--tarpc-bind "unix://$SOCKET_PATH")
        [[ -n "$TCP_PORT" ]] && ARGS+=(--rpc-bind "$TCP_BIND:$TCP_PORT")
        ;;

    rhizocrypt)
        ARGS+=(server)
        [[ -n "$SOCKET_PATH" ]] && ARGS+=(--unix "$SOCKET_PATH")
        [[ -n "$TCP_PORT" ]] && ARGS+=(--port "$TCP_PORT")
        ;;

    sweetgrass|loamspine|skunkbat)
        ARGS+=(server)
        [[ -n "$SOCKET_PATH" ]] && ARGS+=(--socket "$SOCKET_PATH")
        [[ -n "$TCP_PORT" ]] && ARGS+=(--port "$TCP_PORT")
        ;;

    *)
        echo "WARNING: Unknown primal: $PRIMAL — attempting generic start"
        echo "  Trying: $PRIMAL_BIN server ${ARGS[*]:-}"
        ARGS+=(server)
        [[ -n "$TCP_PORT" ]] && export "${PRIMAL^^}_PORT=$TCP_PORT"
        ;;
esac

# ── Capability symlink creation ───────────────────────────────────────────────
# After launch, create well-known capability symlinks so discovery tools can
# find primals by capability name (e.g. security.sock -> beardog-*.sock).
# Primals create some of these themselves, but not all. This fills the gaps.

create_capability_symlinks() {
    local sock_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/biomeos"
    [[ -d "$sock_dir" ]] || return 0
    local fid="${FAMILY_ID:+-$FAMILY_ID}"
    local primal_sock

    # Resolve the actual socket: family-qualified or plain
    if [[ -n "$SOCKET_PATH" ]] && [[ -S "$SOCKET_PATH" ]]; then
        primal_sock="$(basename "$SOCKET_PATH")"
    elif [[ -S "$sock_dir/${PRIMAL}${fid}.sock" ]]; then
        primal_sock="${PRIMAL}${fid}.sock"
    else
        return 0
    fi

    local -a caps=()
    case "$PRIMAL" in
        beardog)       caps=(security crypto btsp ed25519 x25519) ;;
        songbird)      caps=(discovery network) ;;
        toadstool)     caps=(compute) ;;
        barracuda)     caps=(tensor math) ;;
        coralreef)     caps=(shader) ;;
        nestgate)      caps=(storage) ;;
        squirrel)      caps=(ai) ;;
        petaltongue)   caps=(visualization ui) ;;
        rhizocrypt)    caps=(dag memory) ;;
        loamspine)     caps=(ledger) ;;
        sweetgrass)    caps=(attribution provenance commit) ;;
        ludospring)    caps=(game) ;;
    esac

    for cap in "${caps[@]}"; do
        local link="$sock_dir/${cap}.sock"
        if [[ ! -e "$link" ]] || [[ -L "$link" ]]; then
            ln -sf "$primal_sock" "$link" 2>/dev/null && \
                echo "  symlink: ${cap}.sock -> $primal_sock"
        fi
    done
}

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
        create_capability_symlinks
    else
        echo "  status: FAILED (check $LOG_FILE)"
        tail -5 "$LOG_FILE" 2>/dev/null || true
        exit 1
    fi
fi
