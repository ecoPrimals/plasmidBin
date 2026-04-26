#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# plasmidBin/cell_launcher.sh — Deploy a cell graph from plasmidBin
#
# Portable: works on any machine with plasmidBin cloned/fetched.
# No primalSpring source needed. All primal binaries from primals/.
# Cell graphs from cells/. Seeds auto-generated if not provided.
#
# Usage:
#   ./cell_launcher.sh ludospring start       — deploy ludospring cell
#   ./cell_launcher.sh esotericwebb start     — deploy esotericWebb garden
#   ./cell_launcher.sh ludospring stop        — stop all primals
#   ./cell_launcher.sh ludospring status      — health check all primals
#   ./cell_launcher.sh list                   — show available cells
#
# Environment overrides:
#   FAMILY_ID              — identity namespace (default: <cell>-<timestamp>)
#   BEARDOG_FAMILY_SEED    — crypto seed (default: auto-generated from urandom)
#   BIOMEOS_SOCKET_DIR     — socket directory (default: $XDG_RUNTIME_DIR/biomeos)
#   ECOPRIMALS_PLASMID_BIN — plasmidBin path (default: script directory)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CELLS_DIR="$SCRIPT_DIR/cells"
START_PRIMAL="$SCRIPT_DIR/start_primal.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo "[cell] $(date +%H:%M:%S) $*"; }
err()  { echo "[cell] $(date +%H:%M:%S) ERROR: $*" >&2; }
pass() { printf "  ${GREEN}ALIVE${NC}  %s\n" "$1"; }
fail() { printf "  ${RED}DOWN${NC}   %s\n" "$1"; }

usage() {
    echo "Usage: $0 <cell|list> [start|stop|status]"
    echo ""
    echo "Available cells:"
    if [ -d "$CELLS_DIR" ]; then
        for f in "$CELLS_DIR"/*_cell.toml; do
            [ -f "$f" ] || continue
            local stem domain
            stem=$(basename "$f" _cell.toml)
            domain=$(grep 'domain = ' "$f" 2>/dev/null | head -1 | sed 's/.*= "//;s/"//' || echo "unknown")
            echo "  $stem  ($domain)"
        done
    else
        echo "  (no cells/ directory found)"
    fi
    echo ""
    echo "Options:"
    echo "  --family ID         Override family identity"
    echo "  --health-timeout S  Per-primal health timeout (default: 8)"
    echo "  --dry-run           Show plan without executing"
    echo "  --live              Launch petalTongue in native desktop display mode"
    echo "  --headless          Launch petalTongue in headless server mode (default)"
    exit 1
}

[ $# -lt 1 ] && usage

if [ "$1" = "list" ]; then
    echo "Available cells:"
    for f in "$CELLS_DIR"/*_cell.toml; do
        [ -f "$f" ] || continue
        stem=$(basename "$f" _cell.toml)
        domain=$(grep 'domain = ' "$f" 2>/dev/null | head -1 | sed 's/.*= "//;s/"//' || echo "?")
        model=$(grep 'composition_model = ' "$f" 2>/dev/null | head -1 | sed 's/.*= "//;s/"//' || echo "?")
        echo "  $stem  ($domain, $model)"
    done
    exit 0
fi

CELL="$1"
ACTION="${2:-start}"
FAMILY_ID="${FAMILY_ID:-}"
HEALTH_TIMEOUT=8
DRY_RUN=false

shift 2 2>/dev/null || shift 1 2>/dev/null || true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --family)          FAMILY_ID="$2"; shift 2 ;;
        --health-timeout)  HEALTH_TIMEOUT="$2"; shift 2 ;;
        --dry-run)         DRY_RUN=true; shift ;;
        --live)            export PETALTONGUE_MODE=live; shift ;;
        --headless)        export PETALTONGUE_MODE=server; shift ;;
        --help)            usage ;;
        *)                 err "Unknown flag: $1"; usage ;;
    esac
done

CELL_GRAPH="$CELLS_DIR/${CELL}_cell.toml"

if [ ! -f "$CELL_GRAPH" ]; then
    err "Cell graph not found: $CELL_GRAPH"
    echo ""
    echo "Available cells:"
    for f in "$CELLS_DIR"/*_cell.toml; do
        [ -f "$f" ] || continue
        echo "  $(basename "$f" _cell.toml)"
    done
    exit 1
fi

if [ ! -x "$START_PRIMAL" ]; then
    err "start_primal.sh not found at $START_PRIMAL"
    exit 1
fi

# ── Identity & seed ──────────────────────────────────────────────────────

[ -z "$FAMILY_ID" ] && FAMILY_ID="${CELL}-$(date +%s)"
export FAMILY_ID

SOCKET_DIR="${BIOMEOS_SOCKET_DIR:-${XDG_RUNTIME_DIR:-/tmp}/biomeos}"
mkdir -p "$SOCKET_DIR"
export BIOMEOS_SOCKET_DIR="$SOCKET_DIR"
export ECOPRIMALS_PLASMID_BIN="$SCRIPT_DIR"

resolve_family_seed() {
    if [[ -n "${BEARDOG_FAMILY_SEED:-}" ]]; then
        echo "$BEARDOG_FAMILY_SEED"; return
    fi
    if [[ -n "${FAMILY_SEED:-}" ]]; then
        echo "$FAMILY_SEED"; return
    fi
    if [[ -f "$SOCKET_DIR/.family.seed" ]]; then
        cat "$SOCKET_DIR/.family.seed"; return
    fi
    head -c 32 /dev/urandom | xxd -p | tr -d '\n'
}

FAMILY_SEED="$(resolve_family_seed)"
export FAMILY_SEED
export BEARDOG_FAMILY_SEED="$FAMILY_SEED"
echo "$FAMILY_SEED" > "$SOCKET_DIR/.family.seed"

# ── Parse cell graph for ordered node list ───────────────────────────────
# Extracts node names and their order from the TOML, sorts by order.
# Skips nodes named "validate_cell" (validation-only, no binary).

parse_cell_nodes() {
    local graph="$1"
    local current_name="" current_id="" current_order="" current_binary="" current_spawn=""
    local current_by_cap=""
    local in_node=false in_subtable=false node_idx=0

    emit_node() {
        local node_name="${current_name:-$current_id}"
        [[ -z "$node_name" ]] && return
        [[ "$node_name" == validate* ]] && return
        local bin="${current_binary:-$node_name}"
        echo "${current_order:-$node_idx} ${node_name} ${bin} ${current_spawn:-true}"
    }

    while IFS= read -r line; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        [ -z "$line" ] && continue

        # Match both [[graph.nodes]] (primalSpring) and [[nodes]] (biomeOS)
        if [[ "$line" == "[[graph.nodes]]" ]] || [[ "$line" == "[[nodes]]" ]]; then
            if $in_node; then emit_node; fi
            in_node=true
            in_subtable=false
            current_name="" current_id="" current_order="" current_binary=""
            current_spawn="" current_by_cap=""
            node_idx=$((node_idx + 1))
            continue
        fi

        if [[ "$line" == "["* ]]; then
            if [[ "$line" == "[nodes."* ]] || [[ "$line" == "[graph.nodes."* ]]; then
                in_subtable=true
            else
                if $in_node; then emit_node; fi
                in_node=false
                in_subtable=false
            fi
            continue
        fi

        # Only read node-level keys (not sub-table keys like [nodes.operation] name)
        if $in_node && ! $in_subtable; then
            case "$line" in
                name\ =*)          current_name=$(echo "$line" | sed 's/.*= "//;s/".*//') ;;
                id\ =*)            current_id=$(echo "$line" | sed 's/.*= "//;s/".*//') ;;
                order\ =*)         current_order=$(echo "$line" | sed 's/.*= //;s/[[:space:]]*//g') ;;
                binary\ =*)       current_binary=$(echo "$line" | sed 's/.*= "//;s/".*//') ;;
                spawn\ =*)         current_spawn=$(echo "$line" | sed 's/.*= //;s/[[:space:]]*//g') ;;
            esac
        fi
    done < "$graph"

    if $in_node; then emit_node; fi
}

NODES=$(parse_cell_nodes "$CELL_GRAPH" | sort -n)

# ── Health check utility ─────────────────────────────────────────────────

health_check() {
    local name="$1" timeout="${2:-$HEALTH_TIMEOUT}"
    local sock

    for sock in "$SOCKET_DIR/${name}-${FAMILY_ID}.sock" \
                "$SOCKET_DIR/${name}.sock" \
                "$SOCKET_DIR/${name}-${FAMILY_ID}.jsonrpc.sock" \
                "$SOCKET_DIR/${name}.jsonrpc.sock"; do
        [ -S "$sock" ] && break
        sock=""
    done

    if [ -z "$sock" ]; then
        return 1
    fi

    local resp
    resp=$(echo '{"jsonrpc":"2.0","method":"health.liveness","params":{},"id":1}' | \
        timeout "$timeout" socat - UNIX-CONNECT:"$sock" 2>/dev/null || echo "")

    echo "$resp" | grep -q '"result"'
}

# ── Banner ───────────────────────────────────────────────────────────────

cell_domain=$(grep 'domain = ' "$CELL_GRAPH" 2>/dev/null | head -1 | sed 's/.*= "//;s/"//' || echo "unknown")
cell_model=$(grep 'composition_model = ' "$CELL_GRAPH" 2>/dev/null | head -1 | sed 's/.*= "//;s/"//' || echo "nucleated")
cell_pt_mode=$(grep 'petaltongue_mode = ' "$CELL_GRAPH" 2>/dev/null | head -1 | sed 's/.*= "//;s/"//' || echo "server")
node_count=$(echo "$NODES" | wc -l | tr -d ' ')

echo ""
printf "${CYAN}══════════════════════════════════════════════${NC}\n"
printf "${CYAN}  Cell Launcher — plasmidBin portable${NC}\n"
printf "${CYAN}══════════════════════════════════════════════${NC}\n"
echo ""
echo "  Cell:         $CELL"
echo "  Domain:       $cell_domain"
echo "  Model:        $cell_model"
resolved_pt_mode="${PETALTONGUE_MODE:-$cell_pt_mode}"
echo "  Nodes:        $node_count"
echo "  Display:      $resolved_pt_mode"
echo "  Family:       $FAMILY_ID"
echo "  Seed:         ${FAMILY_SEED:0:16}... (${#FAMILY_SEED} chars)"
echo "  Sockets:      $SOCKET_DIR"
echo "  plasmidBin:   $SCRIPT_DIR"
echo "  Action:       $ACTION"
echo ""

# ── Actions ──────────────────────────────────────────────────────────────

case "$ACTION" in
    start)
        if $DRY_RUN; then
            log "DRY RUN — would start these primals in order:"
            echo "$NODES" | while read -r order name binary spawn; do
                printf "  %2s  %-20s  binary=%s\n" "$order" "$name" "$binary"
            done
            exit 0
        fi

        log "Starting primals in dependency order..."
        echo ""

        # Export well-known socket paths for inter-primal discovery
        export BEARDOG_SOCKET="$SOCKET_DIR/beardog-${FAMILY_ID}.sock"
        export BIOMEOS_SOCKET_DIR="$SOCKET_DIR"
        export NODE_ID="${NODE_ID:-$(hostname -s 2>/dev/null || echo 'gate')}"
        export BEARDOG_NODE_ID="$NODE_ID"
        export PETALTONGUE_MODE="${PETALTONGUE_MODE:-$cell_pt_mode}"

        STARTED=0
        SKIPPED=0
        FAILED=0

        while read -r order name binary spawn; do
            # Check if already running (e.g. biomeOS pre-started)
            if health_check "$name" 2; then
                printf "  ${GREEN}ALIVE${NC} %-20s (already running)\n" "$name"
                SKIPPED=$((SKIPPED + 1))
                continue
            fi

            log "Starting $name (order=$order, binary=$binary)..."

            SOCKET_PATH="$SOCKET_DIR/${name}-${FAMILY_ID}.sock"

            "$START_PRIMAL" "$binary" \
                --socket "$SOCKET_PATH" \
                --family-id "$FAMILY_ID" \
                --log-file "/tmp/${name}-${FAMILY_ID}.log" \
                2>&1 | sed 's/^/    /'

            sleep 1

            if health_check "$name" "$HEALTH_TIMEOUT"; then
                pass "$name"
                STARTED=$((STARTED + 1))
            else
                printf "  ${YELLOW}SLOW${NC}  %-20s (not healthy yet, continuing)\n" "$name"
                STARTED=$((STARTED + 1))
            fi

        done <<< "$NODES"

        echo ""
        printf "${CYAN}──────────────────────────────────────────────${NC}\n"
        log "Deployment summary: $STARTED started, $SKIPPED pre-running, $FAILED failed"
        printf "${CYAN}──────────────────────────────────────────────${NC}\n"

        echo ""
        log "Running health sweep..."
        echo ""

        HEALTHY=0
        TOTAL=0
        while read -r order name binary spawn; do
            TOTAL=$((TOTAL + 1))
            if health_check "$name" 3; then
                pass "$name"
                HEALTHY=$((HEALTHY + 1))
            else
                fail "$name"
            fi
        done <<< "$NODES"

        echo ""
        if [[ $HEALTHY -eq $TOTAL ]]; then
            printf "${GREEN}All $HEALTHY/$TOTAL primals healthy.${NC}\n"
        else
            printf "${YELLOW}$HEALTHY/$TOTAL primals healthy.${NC}\n"
        fi

        echo ""
        log "Cell $CELL is deployed. Family: $FAMILY_ID"
        log "Socket dir: $SOCKET_DIR"
        log "To check: $0 $CELL status"
        log "To stop:  $0 $CELL stop"
        ;;

    stop)
        log "Stopping cell $CELL (family=$FAMILY_ID)..."

        while read -r order name binary spawn; do
            for sock in "$SOCKET_DIR/${name}-${FAMILY_ID}.sock" \
                        "$SOCKET_DIR/${name}.sock" \
                        "$SOCKET_DIR/${name}-${FAMILY_ID}.jsonrpc.sock"; do
                [ -S "$sock" ] || continue
                log "  shutdown → $name ($sock)"
                echo '{"jsonrpc":"2.0","method":"lifecycle.shutdown","params":{},"id":1}' | \
                    timeout 3 socat - UNIX-CONNECT:"$sock" 2>/dev/null || true
            done
        done <<< "$(echo "$NODES" | sort -rn)"

        sleep 2
        log "Done."
        ;;

    status)
        HEALTHY=0
        TOTAL=0
        while read -r order name binary spawn; do
            TOTAL=$((TOTAL + 1))
            if health_check "$name" 3; then
                pass "$name"
                HEALTHY=$((HEALTHY + 1))
            else
                fail "$name"
            fi
        done <<< "$NODES"

        echo ""
        echo "  $HEALTHY/$TOTAL primals healthy"
        echo "  Family:  $FAMILY_ID"
        echo "  Sockets: $SOCKET_DIR"
        ;;

    *)
        err "Unknown action: $ACTION"
        usage
        ;;
esac
