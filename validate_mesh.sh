#!/usr/bin/env bash
# plasmidBin/validate_mesh.sh — Validate a multi-node primal mesh
#
# Probes multiple gates, tests BirdSong beacon exchange, and reports
# the mesh health matrix.
#
# Usage:
#   ./validate_mesh.sh localhost 192.168.49.1 73.42.100.50
#   ./validate_mesh.sh --gates "devGate=localhost,pixelGate=192.168.49.1,flockGate=73.42.100.50"
#   ./validate_mesh.sh localhost 192.168.49.1 --birdsong-exchange
#   ./validate_mesh.sh --json localhost 192.168.49.1
#
# Reports:
#   - Per-gate health (TCP + JSON-RPC)
#   - BirdSong beacon status per gate
#   - Mesh peer visibility (who sees whom)
#   - Cross-gate beacon exchange verification

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VALIDATE_GATE="$SCRIPT_DIR/validate_gate.sh"

TIMEOUT=5
JSON_OUTPUT=false
BIRDSONG_EXCHANGE=false
COMPOSITION="tower"

# Source canonical ports (Tier 5 TCP fallback)
# shellcheck source=ports.env
source "$SCRIPT_DIR/ports.env" 2>/dev/null || {
    SONGBIRD_PORT="${SONGBIRD_PORT:-9200}"
    BEARDOG_PORT="${BEARDOG_PORT:-9100}"
}

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

GATES=()
GATE_NAMES=()

usage() {
    echo "Usage: $0 <host1> [host2] [host3] ... [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --gates SPEC           Named gates: 'name1=host1,name2=host2,...'"
    echo "  --composition NAME     tower|compute|node|full (default: tower)"
    echo "  --birdsong-exchange    Test cross-gate beacon encrypt/decrypt"
    echo "  --json                 Machine-readable JSON output"
    echo "  --timeout SECS         Per-probe timeout (default: 5)"
    echo "  --help                 Show this help"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --gates)
            IFS=',' read -ra GATE_SPECS <<< "$2"
            for spec in "${GATE_SPECS[@]}"; do
                name="${spec%%=*}"
                host="${spec##*=}"
                GATE_NAMES+=("$name")
                GATES+=("$host")
            done
            shift 2
            ;;
        --composition)         COMPOSITION="$2"; shift 2 ;;
        --birdsong-exchange)   BIRDSONG_EXCHANGE=true; shift ;;
        --json)                JSON_OUTPUT=true; shift ;;
        --timeout)             TIMEOUT="$2"; shift 2 ;;
        --help)                usage; exit 0 ;;
        -*)                    echo "Unknown option: $1"; usage; exit 1 ;;
        *)
            GATES+=("$1")
            GATE_NAMES+=("gate-${#GATES[@]}")
            shift
            ;;
    esac
done

if [[ ${#GATES[@]} -lt 2 ]]; then
    echo "ERROR: Provide at least 2 gate hosts for mesh validation."
    echo ""
    usage
    exit 1
fi

TOTAL_GATES=${#GATES[@]}

if ! $JSON_OUTPUT; then
    echo "plasmidBin mesh validation — $(date -Iseconds)"
    echo "Gates: $TOTAL_GATES"
    for i in "${!GATES[@]}"; do
        echo "  ${GATE_NAMES[$i]}: ${GATES[$i]}"
    done
    echo ""
fi

# ── Phase 1: Per-gate health ────────────────────────────────────────────────

GATE_HEALTH=()
GATES_OK=0
GATES_FAIL=0

if ! $JSON_OUTPUT; then
    printf "${CYAN}=== Phase 1: Gate Health ===${NC}\n\n"
fi

for i in "${!GATES[@]}"; do
    host="${GATES[$i]}"
    name="${GATE_NAMES[$i]}"

    if ! $JSON_OUTPUT; then
        echo "--- $name ($host) ---"
    fi

    if [[ -x "$VALIDATE_GATE" ]]; then
        if $JSON_OUTPUT; then
            result=$("$VALIDATE_GATE" "$host" --composition "$COMPOSITION" --json --timeout "$TIMEOUT" 2>/dev/null) || result='{"error":"unreachable"}'
            GATE_HEALTH+=("$result")
        else
            "$VALIDATE_GATE" "$host" --composition "$COMPOSITION" --timeout "$TIMEOUT" 2>/dev/null && {
                GATES_OK=$((GATES_OK + 1))
            } || {
                GATES_FAIL=$((GATES_FAIL + 1))
            }
        fi
    else
        # Fallback: simple TCP probe
        for p in beardog songbird; do
            port=$BEARDOG_PORT
            [[ "$p" == "songbird" ]] && port=$SONGBIRD_PORT
            if timeout "$TIMEOUT" bash -c "echo '' > /dev/tcp/$host/$port" 2>/dev/null; then
                printf "  ${GREEN}OK${NC}  %-12s tcp://%s:%s\n" "$p" "$host" "$port"
            else
                printf "  ${RED}--${NC}  %-12s tcp://%s:%s\n" "$p" "$host" "$port"
            fi
        done
    fi

    if ! $JSON_OUTPUT; then
        echo ""
    fi
done

# ── Phase 2: BirdSong beacon status per gate ─────────────────────────────────

if ! $JSON_OUTPUT; then
    printf "${CYAN}=== Phase 2: BirdSong Status ===${NC}\n\n"
fi

BEACON_RESULTS=()

for i in "${!GATES[@]}"; do
    host="${GATES[$i]}"
    name="${GATE_NAMES[$i]}"

    BIRDSONG_PAYLOAD='{"jsonrpc":"2.0","method":"birdsong.generate_encrypted_beacon","params":{"node_id":"mesh_probe","capabilities":["discovery"]},"id":10}'

    response=""
    response=$(curl -sf --max-time "$TIMEOUT" \
        -H "Content-Type: application/json" \
        -d "$BIRDSONG_PAYLOAD" \
        "http://$host:$SONGBIRD_PORT/rpc" 2>/dev/null) || true

    if [[ -z "$response" ]] && command -v nc >/dev/null 2>&1; then
        response=$(echo "$BIRDSONG_PAYLOAD" | timeout "$TIMEOUT" nc -q 1 "$host" "$SONGBIRD_PORT" 2>/dev/null | head -1) || true
    fi

    BEACON_RESULTS+=("$response")

    if ! $JSON_OUTPUT; then
        if [[ -n "$response" && "$response" == *'"encrypted_beacon"'* ]]; then
            printf "  ${GREEN}DARK FOREST${NC}  %-12s %s\n" "$name" "$host"
        elif [[ -n "$response" ]]; then
            printf "  ${YELLOW}BIRDSONG${NC}     %-12s %s (legacy)\n" "$name" "$host"
        else
            printf "  ${RED}NO BEACON${NC}    %-12s %s\n" "$name" "$host"
        fi
    fi
done

if ! $JSON_OUTPUT; then
    echo ""
fi

# ── Phase 3: Mesh peer visibility ────────────────────────────────────────────

if ! $JSON_OUTPUT; then
    printf "${CYAN}=== Phase 3: Mesh Visibility ===${NC}\n\n"
fi

MESH_PAYLOAD='{"jsonrpc":"2.0","method":"mesh.peers","params":{"family_only":true},"id":11}'

for i in "${!GATES[@]}"; do
    host="${GATES[$i]}"
    name="${GATE_NAMES[$i]}"

    mesh_response=""
    mesh_response=$(curl -sf --max-time "$TIMEOUT" \
        -H "Content-Type: application/json" \
        -d "$MESH_PAYLOAD" \
        "http://$host:$SONGBIRD_PORT/rpc" 2>/dev/null) || true

    if [[ -z "$mesh_response" ]] && command -v nc >/dev/null 2>&1; then
        mesh_response=$(echo "$MESH_PAYLOAD" | timeout "$TIMEOUT" nc -q 1 "$host" "$SONGBIRD_PORT" 2>/dev/null | head -1) || true
    fi

    if ! $JSON_OUTPUT; then
        if [[ -n "$mesh_response" && "$mesh_response" == *'"result"'* ]]; then
            peer_count="?"
            if command -v jq >/dev/null 2>&1; then
                peer_count=$(echo "$mesh_response" | jq '.result | length' 2>/dev/null) || peer_count="?"
            fi
            printf "  %-12s sees %s peers\n" "$name" "$peer_count"
            if command -v jq >/dev/null 2>&1; then
                echo "$mesh_response" | jq -r '.result[] | "    → \(.node_id // .id // "unknown")"' 2>/dev/null || true
            fi
        else
            printf "  %-12s ${RED}mesh unavailable${NC}\n" "$name"
        fi
    fi
done

if ! $JSON_OUTPUT; then
    echo ""
fi

# ── Phase 4: Cross-gate beacon exchange ──────────────────────────────────────

if $BIRDSONG_EXCHANGE && [[ ${#GATES[@]} -ge 2 ]]; then
    if ! $JSON_OUTPUT; then
        printf "${CYAN}=== Phase 4: Beacon Exchange ===${NC}\n\n"
    fi

    # Generate beacon on gate 0, attempt decrypt on gate 1
    src_host="${GATES[0]}"
    src_name="${GATE_NAMES[0]}"
    dst_host="${GATES[1]}"
    dst_name="${GATE_NAMES[1]}"

    # Get encrypted beacon from source
    GEN_PAYLOAD='{"jsonrpc":"2.0","method":"birdsong.generate_encrypted_beacon","params":{"node_id":"exchange_test","capabilities":["discovery"]},"id":20}'

    src_beacon=""
    src_beacon=$(curl -sf --max-time "$TIMEOUT" \
        -H "Content-Type: application/json" \
        -d "$GEN_PAYLOAD" \
        "http://$src_host:$SONGBIRD_PORT/rpc" 2>/dev/null) || true

    if [[ -z "$src_beacon" ]] && command -v nc >/dev/null 2>&1; then
        src_beacon=$(echo "$GEN_PAYLOAD" | timeout "$TIMEOUT" nc -q 1 "$src_host" "$SONGBIRD_PORT" 2>/dev/null | head -1) || true
    fi

    if [[ -n "$src_beacon" && "$src_beacon" == *'"encrypted_beacon"'* ]]; then
        if ! $JSON_OUTPUT; then
            printf "  ${GREEN}GENERATED${NC}  beacon from %s\n" "$src_name"
        fi

        # Extract encrypted beacon for decrypt attempt
        if command -v jq >/dev/null 2>&1; then
            encrypted=$(echo "$src_beacon" | jq -r '.result.encrypted_beacon' 2>/dev/null) || encrypted=""

            if [[ -n "$encrypted" && "$encrypted" != "null" ]]; then
                DECRYPT_PAYLOAD="{\"jsonrpc\":\"2.0\",\"method\":\"birdsong.decrypt_beacon\",\"params\":{\"encrypted_beacon\":\"$encrypted\"},\"id\":21}"

                dst_result=""
                dst_result=$(curl -sf --max-time "$TIMEOUT" \
                    -H "Content-Type: application/json" \
                    -d "$DECRYPT_PAYLOAD" \
                    "http://$dst_host:$SONGBIRD_PORT/rpc" 2>/dev/null) || true

                if [[ -z "$dst_result" ]] && command -v nc >/dev/null 2>&1; then
                    dst_result=$(echo "$DECRYPT_PAYLOAD" | timeout "$TIMEOUT" nc -q 1 "$dst_host" "$SONGBIRD_PORT" 2>/dev/null | head -1) || true
                fi

                if ! $JSON_OUTPUT; then
                    if [[ -n "$dst_result" && "$dst_result" == *'"is_family":true'* ]]; then
                        printf "  ${GREEN}FAMILY VERIFIED${NC}  %s decrypted %s's beacon -> is_family: true\n" "$dst_name" "$src_name"
                        echo ""
                        echo "  Shared mitobeacon genetics confirmed across gates."
                    elif [[ -n "$dst_result" && "$dst_result" == *'"is_family":false'* ]]; then
                        printf "  ${RED}NOT FAMILY${NC}  %s could NOT decrypt %s's beacon\n" "$dst_name" "$src_name"
                        echo "  Beacon seeds do not match. Check .beacon.seed distribution."
                    elif [[ -n "$dst_result" ]]; then
                        printf "  ${YELLOW}DECRYPT RESPONSE${NC}  %s\n" "$dst_result"
                    else
                        printf "  ${RED}NO RESPONSE${NC}  %s did not respond to decrypt\n" "$dst_name"
                    fi
                fi
            else
                if ! $JSON_OUTPUT; then
                    printf "  ${YELLOW}SKIP${NC}  Could not extract encrypted_beacon (jq parse)\n"
                fi
            fi
        else
            if ! $JSON_OUTPUT; then
                printf "  ${YELLOW}SKIP${NC}  jq not installed — cannot extract beacon for exchange test\n"
            fi
        fi
    else
        if ! $JSON_OUTPUT; then
            printf "  ${RED}FAILED${NC}  Could not generate beacon from %s\n" "$src_name"
        fi
    fi

    if ! $JSON_OUTPUT; then
        echo ""
    fi
fi

# ── Summary ──────────────────────────────────────────────────────────────────

if $JSON_OUTPUT; then
    echo "{"
    echo "  \"gates\": $TOTAL_GATES,"
    echo "  \"gate_results\": ["
    for i in "${!GATES[@]}"; do
        [[ $i -gt 0 ]] && echo ","
        echo "    {\"name\":\"${GATE_NAMES[$i]}\",\"host\":\"${GATES[$i]}\",\"health\":${GATE_HEALTH[$i]:-null}}"
    done
    echo "  ]"
    echo "}"
else
    printf "${CYAN}=== Mesh Summary ===${NC}\n\n"
    echo "  Gates:     $TOTAL_GATES"
    echo "  Healthy:   $GATES_OK"
    echo "  Failed:    $GATES_FAIL"
    echo ""

    if [[ $GATES_FAIL -eq 0 && $GATES_OK -eq $TOTAL_GATES ]]; then
        printf "  ${GREEN}Mesh fully operational.${NC}\n"
    elif [[ $GATES_OK -gt 0 ]]; then
        printf "  ${YELLOW}Mesh partially operational.${NC}\n"
    else
        printf "  ${RED}Mesh unreachable.${NC}\n"
    fi
fi
