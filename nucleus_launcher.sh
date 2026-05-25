#!/usr/bin/env bash
# plasmidBin/nucleus_launcher.sh — Start a NUCLEUS composition and seed the registry
#
# Orchestrates primal startup in dependency order, waits for health, then
# seeds Songbird's registry with all active primals so downstream springs
# can discover capabilities programmatically.
#
# Usage:
#   ./nucleus_launcher.sh --family-id abc123
#   ./nucleus_launcher.sh --family-id abc123 --composition full --dark-forest
#   ./nucleus_launcher.sh --family-id abc123 --seed-only   # skip startup, just seed
#   ./nucleus_launcher.sh --family-id abc123 --dry-run
#
# Startup order (dependency-aware):
#   1. beardog      (crypto spine — everything depends on this)
#   2. songbird     (discovery + HTTP — registry target)
#   3. toadstool    (compute dispatch)
#   4. barracuda    (GPU math)
#   5. coralreef    (shader compiler)
#   6. nestgate     (storage)
#   7. rhizocrypt   (working memory)
#   8. loamspine    (permanent ledger)
#   9. sweetgrass   (attribution)
#  10. biomeos      (orchestrator — needs primals running)
#  11. squirrel     (AI coordination)
#  12. petaltongue  (UI / representation)
#
# Phase 5 registry seeding:
#   After all primals are healthy, registers each with Songbird so that
#   `ipc.resolve` can route capability queries to the correct primal.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=ports.env
source "$SCRIPT_DIR/ports.env"

FAMILY_ID=""
NODE_ID=""
COMPOSITION="nucleus"
DARK_FOREST=false
SEED_ONLY=false
DRY_RUN=false
VALIDATE=false
HEALTH_TIMEOUT=20
STARTUP_WAIT=3

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --family-id ID       Family ID (REQUIRED)"
    echo "  --node-id ID         Node name (default: hostname)"
    echo "  --composition NAME   tower|node|nest|nucleus|meta|full (default: nucleus)"
    echo "  --dark-forest        Enable Dark Forest beacon mode"
    echo "  --seed-only          Skip startup, only run Phase 5 registry seeding"
    echo "  --health-timeout S   Per-primal health timeout (default: 10)"
    echo "  --validate           Run exp091 + exp094 after startup to confirm composition"
    echo "  --dry-run            Show plan without executing"
    echo "  --help               Show this help"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --family-id)       FAMILY_ID="$2"; shift 2 ;;
        --node-id)         NODE_ID="$2"; shift 2 ;;
        --composition)     COMPOSITION="$2"; shift 2 ;;
        --dark-forest)     DARK_FOREST=true; shift ;;
        --seed-only)       SEED_ONLY=true; shift ;;
        --health-timeout)  HEALTH_TIMEOUT="$2"; shift 2 ;;
        --validate)        VALIDATE=true; shift ;;
        --dry-run)         DRY_RUN=true; shift ;;
        --help)            usage; exit 0 ;;
        -*)                echo "Unknown option: $1"; usage; exit 1 ;;
        *)                 echo "Unknown argument: $1"; usage; exit 1 ;;
    esac
done

if [[ -z "$FAMILY_ID" ]]; then
    echo "ERROR: --family-id is required."
    usage
    exit 1
fi

export FAMILY_ID

RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}/biomeos"
SOCKET_DIR="$RUNTIME_DIR"

resolve_family_seed() {
    if [[ -n "${BEARDOG_FAMILY_SEED:-}" ]]; then
        echo "$BEARDOG_FAMILY_SEED"
        return
    fi
    if [[ -n "${FAMILY_SEED:-}" ]]; then
        echo "$FAMILY_SEED"
        return
    fi
    if [[ -f "$SOCKET_DIR/.family.seed" ]]; then
        cat "$SOCKET_DIR/.family.seed"
        return
    fi
    head -c 32 /dev/urandom | xxd -p | tr -d '\n'
}

FAMILY_SEED="$(resolve_family_seed)"
export FAMILY_SEED
export BEARDOG_FAMILY_SEED="$FAMILY_SEED"

[[ -z "$NODE_ID" ]] && NODE_ID="$(hostname -s 2>/dev/null || echo 'nucleus')"

PRIMALS_REQUESTED=$(primals_for_composition "$COMPOSITION")

STARTUP_ORDER="beardog songbird toadstool barracuda coralreef nestgate rhizocrypt loamspine sweetgrass biomeos squirrel petaltongue"

ORDERED_PRIMALS=""
for p in $STARTUP_ORDER; do
    for req in $PRIMALS_REQUESTED; do
        if [[ "$p" == "$req" ]]; then
            ORDERED_PRIMALS="$ORDERED_PRIMALS $p"
            break
        fi
    done
done
ORDERED_PRIMALS="${ORDERED_PRIMALS# }"

echo ""
printf "${CYAN}══════════════════════════════════════════════${NC}\n"
printf "${CYAN}  NUCLEUS Launcher${NC}\n"
printf "${CYAN}══════════════════════════════════════════════${NC}\n"
echo ""
echo "  Family:      $FAMILY_ID"
echo "  Node:        $NODE_ID"
echo "  Composition: $COMPOSITION"
echo "  Primals:     $ORDERED_PRIMALS"
echo "  Seed:        ${FAMILY_SEED:0:16}... (${#FAMILY_SEED} chars)"
echo "  Dark Forest: $DARK_FOREST"
echo ""

mkdir -p "$SOCKET_DIR"
echo "$FAMILY_SEED" > "$SOCKET_DIR/.family.seed"

# ── Capability map for Phase 5 seeding ────────────────────────────────────
# Maps primal names to the capability domains they provide.
# Songbird's ipc.register uses these to build the route table.
capability_domains_for() {
    case "$1" in
        beardog)     echo "security crypto btsp birdsong lineage entropy jwt" ;;
        songbird)    echo "discovery http tls mesh stun relay onion" ;;
        toadstool)   echo "compute cpu gpu npu wasm orchestration" ;;
        barracuda)   echo "tensor linalg spectral stats fhe wgsl" ;;
        coralreef)   echo "shader spirv wgsl glsl naga compile vfio" ;;
        nestgate)    echo "storage provenance compression" ;;
        rhizocrypt)  echo "dag session ephemeral" ;;
        loamspine)   echo "ledger permanent audit" ;;
        sweetgrass)  echo "attribution prov-o" ;;
        biomeos)     echo "orchestration graph deploy nucleus spore niche" ;;
        squirrel)    echo "ai inference mcp" ;;
        petaltongue) echo "visualization ui interaction representation" ;;
        *)           echo "" ;;
    esac
}

# ── Health check ──────────────────────────────────────────────────────────
check_health() {
    local primal="$1"
    local port
    port=$(port_for_primal "$primal")

    local payload='{"jsonrpc":"2.0","method":"health.check","params":{},"id":1}'

    if command -v nc >/dev/null 2>&1; then
        local response
        response=$(echo "$payload" | timeout "$HEALTH_TIMEOUT" nc -q 1 127.0.0.1 "$port" 2>/dev/null | head -1) || true
        if [[ "$response" == *'"jsonrpc"'* ]]; then
            return 0
        fi
    fi

    if command -v curl >/dev/null 2>&1; then
        local http_resp
        http_resp=$(curl -sf --max-time "$HEALTH_TIMEOUT" "http://127.0.0.1:$port/health" 2>/dev/null) || true
        if [[ -n "$http_resp" ]]; then
            return 0
        fi

        http_resp=$(curl -sf --max-time "$HEALTH_TIMEOUT" \
            -H "Content-Type: application/json" \
            -d "$payload" \
            "http://127.0.0.1:$port/rpc" 2>/dev/null) || true
        if [[ -n "$http_resp" ]]; then
            return 0
        fi
    fi

    return 1
}

# ── Phase 1–4: Start primals ─────────────────────────────────────────────

if ! $SEED_ONLY; then
    echo "=== Phase 1: Prepare runtime ==="
    if ! $DRY_RUN; then
        mkdir -p "$SOCKET_DIR"
    fi
    echo "  Runtime: $RUNTIME_DIR"
    echo "  Sockets: $SOCKET_DIR"
    echo ""

    echo "=== Phase 2: Stop existing primals ==="
    for p in $ORDERED_PRIMALS; do
        pkill -f "primals/.*$p" 2>/dev/null || true
    done
    sleep 1
    echo "  Cleared."
    echo ""

    echo "=== Phase 3: Start primals (dependency order) ==="
    echo ""

    STARTED=0
    FAILED_START=0

    for p in $ORDERED_PRIMALS; do
        PORT=$(port_for_primal "$p")
        SOCKET="$SOCKET_DIR/${p}-${FAMILY_ID}.sock"

        printf "  %-14s tcp=%-5s " "$p" "$PORT"

        if $DRY_RUN; then
            printf "${YELLOW}[dry-run]${NC}\n"
            STARTED=$((STARTED + 1))
            continue
        fi

        DF_FLAG=""
        $DARK_FOREST && DF_FLAG="--dark-forest"

        EXTRA_FLAGS=""
        if [[ "$p" == "songbird" ]]; then
            BD_SOCK="$SOCKET_DIR/beardog-${FAMILY_ID}.sock"
            [[ -S "$BD_SOCK" ]] && EXTRA_FLAGS="--beardog-socket $BD_SOCK"
            if [[ -n "${SONGBIRD_FEDERATION_PORT:-}" ]]; then
                export SONGBIRD_HTTP_PORT="$SONGBIRD_FEDERATION_PORT"
            fi
        fi

        "$SCRIPT_DIR/start_primal.sh" "$p" \
            --tcp-port "$PORT" \
            --socket "$SOCKET" \
            --family-id "$FAMILY_ID" \
            $DF_FLAG $EXTRA_FLAGS \
            --log-file "/tmp/${p}.log" \
            > /dev/null 2>&1 || true

        sleep "$STARTUP_WAIT"

        if check_health "$p"; then
            printf "${GREEN}ALIVE${NC}\n"
            STARTED=$((STARTED + 1))
        else
            printf "${YELLOW}STARTED${NC} (health probe pending)\n"
            STARTED=$((STARTED + 1))
        fi
    done

    echo ""
    echo "  Started: $STARTED / $(echo "$ORDERED_PRIMALS" | wc -w | tr -d ' ')"
    echo ""

    echo "=== Phase 4: Health sweep ==="
    HEALTHY=0
    UNHEALTHY=0

    for p in $ORDERED_PRIMALS; do
        PORT=$(port_for_primal "$p")
        printf "  %-14s :%s  " "$p" "$PORT"

        if $DRY_RUN; then
            printf "${YELLOW}[dry-run]${NC}\n"
            HEALTHY=$((HEALTHY + 1))
            continue
        fi

        if check_health "$p"; then
            printf "${GREEN}HEALTHY${NC}\n"
            HEALTHY=$((HEALTHY + 1))
        else
            printf "${RED}UNREACHABLE${NC}  (check /tmp/${p}.log)\n"
            UNHEALTHY=$((UNHEALTHY + 1))
        fi
    done

    echo ""
    echo "  Healthy: $HEALTHY / $(echo "$ORDERED_PRIMALS" | wc -w | tr -d ' ')"
    if [[ $UNHEALTHY -gt 0 ]]; then
        printf "  ${YELLOW}Some primals not responding — Phase 5 will attempt seeding anyway.${NC}\n"
    fi
    echo ""
fi

# ── Phase 5: Registry seeding ────────────────────────────────────────────

echo "=== Phase 5: Registry seeding (Songbird ipc.register) ==="

SB_PORT=$(port_for_primal "songbird")
REGISTERED=0
REG_SKIPPED=0

for p in $ORDERED_PRIMALS; do
    [[ "$p" == "songbird" ]] && continue

    PORT=$(port_for_primal "$p")
    CAPS=$(capability_domains_for "$p")
    SOCKET="$SOCKET_DIR/${p}-${FAMILY_ID}.sock"

    if [[ -z "$CAPS" ]]; then
        continue
    fi

    CAPS_JSON=$(echo "$CAPS" | tr ' ' '\n' | sed 's/.*/"&"/' | paste -sd',' | sed 's/^/[/;s/$/]/')

    REGISTER_PAYLOAD=$(cat <<EOPAYLOAD
{"jsonrpc":"2.0","method":"ipc.register","params":{"name":"$p","capabilities":$CAPS_JSON,"endpoint":"unix://$SOCKET","tcp_endpoint":"tcp://127.0.0.1:$PORT","family_id":"$FAMILY_ID","node_id":"$NODE_ID"},"id":99}
EOPAYLOAD
)

    printf "  %-14s %s  " "$p" "$CAPS_JSON"

    if $DRY_RUN; then
        printf "${YELLOW}[dry-run]${NC}\n"
        REGISTERED=$((REGISTERED + 1))
        continue
    fi

    REG_RESP=""
    if command -v curl >/dev/null 2>&1; then
        REG_RESP=$(curl -sf --max-time 5 \
            -H "Content-Type: application/json" \
            -d "$REGISTER_PAYLOAD" \
            "http://127.0.0.1:$SB_PORT/rpc" 2>/dev/null) || true
    fi

    if [[ -z "$REG_RESP" ]] && command -v nc >/dev/null 2>&1; then
        REG_RESP=$(echo "$REGISTER_PAYLOAD" | timeout 5 nc -q 1 127.0.0.1 "$SB_PORT" 2>/dev/null | head -1) || true
    fi

    if [[ "$REG_RESP" == *'"result"'* ]]; then
        printf "${GREEN}OK${NC}\n"
        REGISTERED=$((REGISTERED + 1))
    elif [[ -n "$REG_RESP" ]]; then
        printf "${YELLOW}RESP${NC} (non-standard: ${REG_RESP:0:60}...)\n"
        REGISTERED=$((REGISTERED + 1))
    else
        printf "${RED}FAIL${NC} (Songbird not responding on $SB_PORT)\n"
        REG_SKIPPED=$((REG_SKIPPED + 1))
    fi
done

echo ""
echo "  Registered: $REGISTERED"
[[ $REG_SKIPPED -gt 0 ]] && echo "  Skipped:    $REG_SKIPPED"
echo ""

# ── Summary ──────────────────────────────────────────────────────────────

printf "${CYAN}══════════════════════════════════════════════${NC}\n"
printf "${CYAN}  NUCLEUS Ready${NC}\n"
printf "${CYAN}══════════════════════════════════════════════${NC}\n"
echo ""
echo "  Composition: $COMPOSITION"
echo "  Family:      $FAMILY_ID"
echo "  Node:        $NODE_ID"
echo ""
echo "  Validate:"
echo "    ./validate_composition.sh $COMPOSITION --live"
echo "    ./validate_gate.sh 127.0.0.1 --composition $COMPOSITION"
echo ""
echo "  Discover capabilities:"
echo "    curl -s http://127.0.0.1:$SB_PORT/rpc \\"
echo "      -H 'Content-Type: application/json' \\"
echo "      -d '{\"jsonrpc\":\"2.0\",\"method\":\"ipc.resolve\",\"params\":{\"capability\":\"tensor\"},\"id\":1}'"
echo ""
echo "  Stop:"
echo "    ./stop_gate.sh"
echo ""
echo "  Logs: /tmp/{beardog,songbird,...}.log"

# ── Phase 6 (optional): Composition validation ──────────────────────────
if $VALIDATE && ! $DRY_RUN; then
    echo ""
    printf "${CYAN}=== Phase 6: Composition Validation ===${NC}\n"
    echo ""

    SPRING_ROOT=""
    for candidate in \
        "$SCRIPT_DIR/../../springs/primalSpring" \
        "$SCRIPT_DIR/../../../springs/primalSpring" \
        "${PRIMALSPRING_ROOT:-}"; do
        if [[ -d "$candidate/experiments" ]]; then
            SPRING_ROOT="$(cd "$candidate" && pwd)"
            break
        fi
    done

    if [[ -z "$SPRING_ROOT" ]]; then
        printf "  ${YELLOW}SKIP${NC} — primalSpring root not found (set PRIMALSPRING_ROOT)\n"
    else
        echo "  primalSpring: $SPRING_ROOT"
        echo ""

        for exp in exp091_primal_routing_matrix exp094_composition_parity; do
            pkg="primalspring-${exp}"
            printf "  %-42s " "$exp"
            if cargo run --release -p "$pkg" --manifest-path "$SPRING_ROOT/Cargo.toml" 2>/dev/null | grep -q "FAIL\|PANIC"; then
                printf "${RED}FAIL${NC}\n"
            else
                printf "${GREEN}PASS${NC}\n"
            fi
        done
        echo ""
    fi
fi
