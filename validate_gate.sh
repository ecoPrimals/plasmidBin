#!/usr/bin/env bash
# plasmidBin/validate_gate.sh — Validate a remote gate's primal health over TCP
#
# Probes a remote machine's primal TCP endpoints with JSON-RPC health checks.
# Works from any machine — no SSH needed, just TCP connectivity.
#
# Usage:
#   ./validate_gate.sh 192.168.1.42                   # Probe default ports
#   ./validate_gate.sh 192.168.1.42 --composition compute
#   ./validate_gate.sh friend.dyndns.org --all        # Probe all standard ports
#   ./validate_gate.sh 10.0.0.5 --json                # Machine-readable output
#
# Standard ports (from primalSpring tolerances):
#   beardog=9100 songbird=9200 squirrel=9300 toadstool=9400 nestgate=9500
#
# Requires: curl (for JSON-RPC) or bash /dev/tcp (for raw probes)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=ports.env
source "$SCRIPT_DIR/ports.env"

HOST=""
COMPOSITION="tower"
PROBE_ALL=false
JSON_OUTPUT=false
TIMEOUT=5
PROBE_BIRDSONG=false
PROBE_MESH=false

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

usage() {
    echo "Usage: $0 <host> [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --composition NAME   tower|node|nest|nucleus|meta|full|niche-<spring> (default: tower)"
    echo "  --all                Probe all standard primal ports"
    echo "  --birdsong           Test BirdSong beacon generation + Dark Forest"
    echo "  --mesh               Query mesh.peers for discovered nodes"
    echo "  --json               Machine-readable JSON output"
    echo "  --timeout SECS       Per-probe timeout (default: 5)"
    echo "  --help               Show this help"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --composition)  COMPOSITION="$2"; shift 2 ;;
        --all)          PROBE_ALL=true; shift ;;
        --birdsong)     PROBE_BIRDSONG=true; shift ;;
        --mesh)         PROBE_MESH=true; shift ;;
        --json)         JSON_OUTPUT=true; shift ;;
        --timeout)      TIMEOUT="$2"; shift 2 ;;
        --help)         usage; exit 0 ;;
        -*)             echo "Unknown option: $1"; usage; exit 1 ;;
        *)              HOST="$1"; shift ;;
    esac
done

if [[ -z "$HOST" ]]; then
    echo "ERROR: Specify remote host"
    usage
    exit 1
fi

if $PROBE_ALL; then
    PRIMALS="$ALL_PRIMALS"
else
    PRIMALS=$(primals_for_composition "$COMPOSITION")
fi

# TCP reachability probe (bash built-in)
tcp_reachable() {
    local host="$1"
    local port="$2"
    timeout "$TIMEOUT" bash -c "echo '' > /dev/tcp/$host/$port" 2>/dev/null
}

# Probe health — tries raw TCP JSON-RPC first, then HTTP /health
probe_health() {
    local host="$1"
    local port="$2"
    local primal="$3"

    # Try raw TCP JSON-RPC (beardog, nestgate style)
    local payload='{"jsonrpc":"2.0","method":"health.check","params":{},"id":1}'
    local response
    if command -v nc >/dev/null 2>&1; then
        response=$(echo "$payload" | timeout "$TIMEOUT" nc -q 1 "$host" "$port" 2>/dev/null | head -1) || true
        if [[ "$response" == *'"jsonrpc"'* ]]; then
            echo "$response"
            return 0
        fi
    fi

    # Try HTTP /health (songbird style)
    response=$(curl -sf --max-time "$TIMEOUT" "http://$host:$port/health" 2>/dev/null) || true
    if [[ -n "$response" ]]; then
        local escaped
        escaped=$(echo "$response" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\n/\\n/g' | tr -d '\n')
        echo "{\"result\":{\"status\":\"healthy\",\"protocol\":\"HTTP\",\"raw\":\"$escaped\"}}"
        return 0
    fi

    # Try HTTP JSON-RPC POST (squirrel style)
    response=$(curl -sf --max-time "$TIMEOUT" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "http://$host:$port/rpc" 2>/dev/null) || true
    if [[ -n "$response" ]]; then
        echo "$response"
        return 0
    fi

    return 1
}

# Probe capabilities — raw TCP or HTTP
probe_capabilities() {
    local host="$1"
    local port="$2"

    local payload='{"jsonrpc":"2.0","method":"capabilities.list","params":{},"id":2}'

    if command -v nc >/dev/null 2>&1; then
        local response
        response=$(echo "$payload" | timeout "$TIMEOUT" nc -q 1 "$host" "$port" 2>/dev/null | head -1) || true
        if [[ "$response" == *'"jsonrpc"'* ]]; then
            echo "$response"
            return 0
        fi
    fi

    curl -sf --max-time "$TIMEOUT" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "http://$host:$port/rpc" 2>/dev/null || true
}

TOTAL=0
REACHABLE=0
HEALTHY=0
FAILED=0

JSON_RESULTS="["

if ! $JSON_OUTPUT; then
    echo "plasmidBin gate validation — $(date -Iseconds)"
    echo "Host: $HOST"
    echo "Composition: $COMPOSITION"
    echo ""
fi

for p in $PRIMALS; do
    PORT=$(port_for_primal "$p")
    TOTAL=$((TOTAL + 1))
    status="unreachable"
    health=""
    caps=""

    if tcp_reachable "$HOST" "$PORT"; then
        REACHABLE=$((REACHABLE + 1))
        status="reachable"

        health_response=$(probe_health "$HOST" "$PORT" "$p" 2>/dev/null) || true
        if [[ -n "$health_response" ]]; then
            HEALTHY=$((HEALTHY + 1))
            status="healthy"
            health="$health_response"

            caps_response=$(probe_capabilities "$HOST" "$PORT" 2>/dev/null) || true
            if [[ -n "$caps_response" ]]; then
                caps="$caps_response"
            fi
        fi
    else
        FAILED=$((FAILED + 1))
    fi

    if $JSON_OUTPUT; then
        [[ $TOTAL -gt 1 ]] && JSON_RESULTS+=","
        JSON_RESULTS+="{\"primal\":\"$p\",\"port\":$PORT,\"status\":\"$status\""
        [[ -n "$health" ]] && JSON_RESULTS+=",\"health\":$health"
        [[ -n "$caps" ]] && JSON_RESULTS+=",\"capabilities\":$caps"
        JSON_RESULTS+="}"
    else
        case "$status" in
            healthy)
                printf "  ${GREEN}OK${NC}  %-12s tcp://%s:%s" "$p" "$HOST" "$PORT"
                if [[ -n "$caps" ]] && command -v jq >/dev/null 2>&1; then
                    cap_count=$(echo "$caps" | jq -r '.result | length' 2>/dev/null) || cap_count="?"
                    printf "  (%s capabilities)" "$cap_count"
                fi
                echo ""
                ;;
            reachable)
                printf "  ${YELLOW}TCP${NC} %-12s tcp://%s:%s  (port open, JSON-RPC not responding)\n" "$p" "$HOST" "$PORT"
                ;;
            unreachable)
                printf "  ${RED}--${NC}  %-12s tcp://%s:%s  (not reachable)\n" "$p" "$HOST" "$PORT"
                ;;
        esac
    fi
done

if $JSON_OUTPUT; then
    JSON_RESULTS+="]"
    echo "{\"host\":\"$HOST\",\"composition\":\"$COMPOSITION\",\"total\":$TOTAL,\"reachable\":$REACHABLE,\"healthy\":$HEALTHY,\"failed\":$FAILED,\"primals\":$JSON_RESULTS}"
else
    echo ""
    echo "Summary:"
    echo "  Total:     $TOTAL"
    echo "  Healthy:   $HEALTHY"
    echo "  Reachable: $REACHABLE (TCP open but no JSON-RPC: $((REACHABLE - HEALTHY)))"
    echo "  Failed:    $FAILED"

    if [[ $HEALTHY -eq $TOTAL ]]; then
        printf "\n${GREEN}Gate fully operational.${NC}\n"
    elif [[ $REACHABLE -gt 0 ]]; then
        printf "\n${YELLOW}Gate partially operational — some primals starting or misconfigured.${NC}\n"
    else
        printf "\n${RED}Gate unreachable — check network, firewall, SSH logs.${NC}\n"
    fi
fi

# ── BirdSong beacon probe ────────────────────────────────────────────────────

if $PROBE_BIRDSONG; then
    if ! $JSON_OUTPUT; then
        echo ""
        echo "=== BirdSong Beacon Probe ==="
    fi

    BIRDSONG_PAYLOAD='{"jsonrpc":"2.0","method":"birdsong.generate_encrypted_beacon","params":{"node_id":"validate_probe","capabilities":["discovery"]},"id":10}'

    birdsong_response=""

    # Try via Songbird HTTP (port 9200)
    birdsong_response=$(curl -sf --max-time "$TIMEOUT" \
        -H "Content-Type: application/json" \
        -d "$BIRDSONG_PAYLOAD" \
        "http://$HOST:$SONGBIRD_PORT/rpc" 2>/dev/null) || true

    if [[ -z "$birdsong_response" ]] && command -v nc >/dev/null 2>&1; then
        birdsong_response=$(echo "$BIRDSONG_PAYLOAD" | timeout "$TIMEOUT" nc -q 1 "$HOST" "$SONGBIRD_PORT" 2>/dev/null | head -1) || true
    fi

    if $JSON_OUTPUT; then
        if [[ -n "$birdsong_response" && "$birdsong_response" == *'"encrypted_beacon"'* ]]; then
            echo "{\"birdsong\":{\"status\":\"active\",\"dark_forest\":true,\"response\":$birdsong_response}}"
        elif [[ -n "$birdsong_response" ]]; then
            echo "{\"birdsong\":{\"status\":\"responding\",\"dark_forest\":false,\"response\":$birdsong_response}}"
        else
            echo "{\"birdsong\":{\"status\":\"unavailable\"}}"
        fi
    else
        if [[ -n "$birdsong_response" && "$birdsong_response" == *'"encrypted_beacon"'* ]]; then
            printf "  ${GREEN}DARK FOREST ACTIVE${NC}\n"
            if command -v jq >/dev/null 2>&1; then
                family_id=$(echo "$birdsong_response" | jq -r '.result.family_id // "unknown"' 2>/dev/null) || family_id="(parse error)"
                beacon_len=$(echo "$birdsong_response" | jq -r '.result.encrypted_beacon | length' 2>/dev/null) || beacon_len="?"
                echo "    Family ID:     $family_id"
                echo "    Beacon length: $beacon_len chars (encrypted)"
            fi
        elif [[ -n "$birdsong_response" ]]; then
            printf "  ${YELLOW}BIRDSONG RESPONDING${NC} (legacy mode — not Dark Forest)\n"
        else
            printf "  ${RED}BIRDSONG UNAVAILABLE${NC} (Songbird not responding on $SONGBIRD_PORT)\n"
        fi
    fi
fi

# ── Mesh peers probe ────────────────────────────────────────────────────────

if $PROBE_MESH; then
    if ! $JSON_OUTPUT; then
        echo ""
        echo "=== Mesh Peers ==="
    fi

    MESH_PAYLOAD='{"jsonrpc":"2.0","method":"mesh.peers","params":{"family_only":true},"id":11}'

    mesh_response=""

    mesh_response=$(curl -sf --max-time "$TIMEOUT" \
        -H "Content-Type: application/json" \
        -d "$MESH_PAYLOAD" \
        "http://$HOST:$SONGBIRD_PORT/rpc" 2>/dev/null) || true

    if [[ -z "$mesh_response" ]] && command -v nc >/dev/null 2>&1; then
        mesh_response=$(echo "$MESH_PAYLOAD" | timeout "$TIMEOUT" nc -q 1 "$HOST" "$SONGBIRD_PORT" 2>/dev/null | head -1) || true
    fi

    if $JSON_OUTPUT; then
        if [[ -n "$mesh_response" ]]; then
            echo "{\"mesh\":$mesh_response}"
        else
            echo "{\"mesh\":{\"status\":\"unavailable\"}}"
        fi
    else
        if [[ -n "$mesh_response" && "$mesh_response" == *'"result"'* ]]; then
            if command -v jq >/dev/null 2>&1; then
                peer_count=$(echo "$mesh_response" | jq '.result | length' 2>/dev/null) || peer_count="?"
                printf "  ${GREEN}MESH ACTIVE${NC} — %s peers discovered\n" "$peer_count"
                echo "$mesh_response" | jq -r '.result[] | "    \(.node_id // .id // "unknown") — \(.endpoint // "no endpoint")"' 2>/dev/null || true
            else
                printf "  ${GREEN}MESH ACTIVE${NC}\n"
                echo "    $mesh_response"
            fi
        elif [[ -n "$mesh_response" ]]; then
            printf "  ${YELLOW}MESH RESPONDING${NC} (no peers yet)\n"
        else
            printf "  ${RED}MESH UNAVAILABLE${NC}\n"
        fi
    fi
fi

if [[ $FAILED -gt 0 ]]; then
    exit 1
fi
