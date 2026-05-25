#!/usr/bin/env bash
# plasmidBin/validate_composition.sh — Validate a composition is deployable
#
# Three-phase validation:
#   1. Manifest check: all primals for the composition exist in manifest.toml
#   2. Binary check: all binaries are present, static, stripped, checksummed
#   3. Live check (optional): probe running primals via UDS or TCP
#
# Usage:
#   ./validate_composition.sh tower                # Check Tower atomic
#   ./validate_composition.sh nucleus              # Check NUCLEUS (9 primals)
#   ./validate_composition.sh full                 # Check NUCLEUS + Meta
#   ./validate_composition.sh niche-hotspring      # What hotSpring needs
#   ./validate_composition.sh niche-neuralspring   # What neuralSpring needs
#   ./validate_composition.sh full --live          # Also probe live health
#   ./validate_composition.sh full --live --host 192.168.1.42
#   ./validate_composition.sh --json               # Machine-readable
#
# Spring niche compositions (niche-<spring>) validate the PRIMALS a spring
# needs deployed to run its science. Springs do not ship their own binaries;
# they compose NUCLEUS primals.
#
# Evolution ladder: Research paper → Python → Rust → Primal composition
#
# Exit codes:
#   0 = all checks pass
#   1 = failures detected
#   2 = composition unknown

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=ports.env
source "$SCRIPT_DIR/ports.env"

COMPOSITION="${1:-}"
shift || true

LIVE=false
HOST=""
JSON=false
TIMEOUT=5

while [[ $# -gt 0 ]]; do
    case "$1" in
        --live)     LIVE=true; shift ;;
        --host)     HOST="$2"; LIVE=true; shift 2 ;;
        --json)     JSON=true; shift ;;
        --timeout)  TIMEOUT="$2"; shift 2 ;;
        --help)
            echo "Usage: $0 <composition> [--live] [--host HOST] [--json] [--timeout N]"
            echo ""
            echo "Atomic compositions:"
            echo "  tower, node, nest, nucleus, meta, full"
            echo ""
            echo "Spring niche compositions (primals a spring needs):"
            echo "  niche-hotspring, niche-neuralspring, niche-wetspring,"
            echo "  niche-airspring, niche-groundspring, niche-healthspring,"
            echo "  niche-ludospring"
            echo ""
            echo "Legacy aliases: compute, provenance, science"
            echo ""
            echo "Phases:"
            echo "  1. Manifest: primals exist in manifest.toml with correct atomics"
            echo "  2. Binary: binaries present, static, stripped, checksum verified"
            echo "  3. Live (--live): JSON-RPC health + capabilities probes"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ -z "$COMPOSITION" ]]; then
    echo "ERROR: Specify composition (tower, node, nest, nucleus, meta, full)"
    exit 2
fi

PRIMALS=$(primals_for_composition "$COMPOSITION" 2>/dev/null) || {
    echo "ERROR: Unknown composition: $COMPOSITION"
    exit 2
}

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
WARN=0
FAIL=0

check() {
    local label="$1"
    local status="$2"
    local detail="${3:-}"

    case "$status" in
        pass) PASS=$((PASS + 1))
              if ! $JSON; then printf "  ${GREEN}PASS${NC} %s" "$label"; fi ;;
        warn) WARN=$((WARN + 1))
              if ! $JSON; then printf "  ${YELLOW}WARN${NC} %s" "$label"; fi ;;
        fail) FAIL=$((FAIL + 1))
              if ! $JSON; then printf "  ${RED}FAIL${NC} %s" "$label"; fi ;;
    esac
    if ! $JSON && [[ -n "$detail" ]]; then
        echo "  ($detail)"
    elif ! $JSON; then
        echo ""
    fi
}

if ! $JSON; then
    echo "plasmidBin composition validation — $(date -Iseconds)"
    echo "Composition: $COMPOSITION"
    echo "Primals:     $PRIMALS"
    echo ""
fi

# =============================================================================
# Phase 1: Manifest validation
# =============================================================================

if ! $JSON; then
    printf "${CYAN}=== Phase 1: Manifest ===${NC}\n"
fi

MANIFEST="$SCRIPT_DIR/manifest.toml"
if [[ ! -f "$MANIFEST" ]]; then
    check "manifest.toml" fail "missing"
else
    check "manifest.toml" pass

    for p in $PRIMALS; do
        if grep -q "^\[primals\.$p\]" "$MANIFEST" 2>/dev/null; then
            check "$p in manifest" pass
        elif grep -q "^\[springs\.$p\]" "$MANIFEST" 2>/dev/null; then
            check "$p in manifest" pass "spring"
        else
            check "$p in manifest" fail "not found"
        fi
    done
fi

if ! $JSON; then echo ""; fi

# =============================================================================
# Phase 2: Binary validation
# =============================================================================

if ! $JSON; then
    printf "${CYAN}=== Phase 2: Binaries ===${NC}\n"
fi

PRIMALS_DIR="$SCRIPT_DIR/primals"

CURRENT_ARCH=$(uname -m)
case "$CURRENT_ARCH" in
    x86_64)  CURRENT_ARCH="x86_64-unknown-linux-musl" ;;
    aarch64) CURRENT_ARCH="aarch64-unknown-linux-musl" ;;
    armv7l)  CURRENT_ARCH="armv7-unknown-linux-musleabihf" ;;
esac

for p in $PRIMALS; do
    bin=""
    if [[ -f "$PRIMALS_DIR/$p" ]]; then
        bin="$PRIMALS_DIR/$p"
    elif [[ -f "$PRIMALS_DIR/$CURRENT_ARCH/$p" ]]; then
        bin="$PRIMALS_DIR/$CURRENT_ARCH/$p"
    elif [[ -f "$SCRIPT_DIR/$p/$p" ]]; then
        bin="$SCRIPT_DIR/$p/$p"
    fi

    if [[ -z "$bin" ]]; then
        check "$p binary" fail "not found in primals/, primals/$CURRENT_ARCH/, or $p/$p"
        continue
    fi

    file_out=$(file "$bin" 2>/dev/null)
    is_static=false
    is_stripped=false
    if echo "$file_out" | grep -qE "statically linked|static-pie"; then is_static=true; fi
    if ! echo "$file_out" | grep -q "not stripped"; then is_stripped=true; fi

    sz=$(du -h "$bin" | cut -f1)

    if $is_static && $is_stripped; then
        check "$p binary" pass "${sz}, static, stripped"
    elif $is_static; then
        check "$p binary" warn "${sz}, static, NOT stripped"
    elif $is_stripped; then
        check "$p binary" warn "${sz}, dynamic, stripped"
    else
        check "$p binary" warn "${sz}, dynamic, not stripped"
    fi

    # Checksum verification
    if command -v b3sum >/dev/null 2>&1 && [[ -f "$SCRIPT_DIR/checksums.toml" ]]; then
        ARCH=$(uname -m)
        case "$ARCH" in
            x86_64)  TRIPLE="x86_64-unknown-linux-musl" ;;
            aarch64) TRIPLE="aarch64-unknown-linux-musl" ;;
            armv7l)  TRIPLE="armv7-unknown-linux-musleabihf" ;;
            *)       TRIPLE="$ARCH-unknown-linux-musl" ;;
        esac

        section="primals.$p"
        expected=$(grep -A3 "^\[$section\]" "$SCRIPT_DIR/checksums.toml" 2>/dev/null | \
                   grep "\"$TRIPLE\"" | grep -oP '"\K[a-f0-9]{64}' | head -1) || expected=""

        if [[ -z "$expected" ]]; then
            check "$p checksum" warn "no entry in checksums.toml"
        else
            actual=$(b3sum --no-names "$bin")
            if [[ "$actual" == "$expected" ]]; then
                check "$p checksum" pass
            else
                check "$p checksum" fail "blake3 mismatch"
            fi
        fi
    fi
done

if ! $JSON; then echo ""; fi

# =============================================================================
# Phase 3: Live validation (optional)
# =============================================================================

if $LIVE; then
    if ! $JSON; then
        printf "${CYAN}=== Phase 3: Live Health ===${NC}\n"
    fi

    for p in $PRIMALS; do
        PORT=$(port_for_primal "$p")

        if [[ -n "$HOST" ]]; then
            # Remote TCP probe
            if timeout "$TIMEOUT" bash -c "echo '' > /dev/tcp/$HOST/$PORT" 2>/dev/null; then
                payload='{"jsonrpc":"2.0","method":"health.liveness","params":{},"id":1}'
                response=""
                if command -v nc >/dev/null 2>&1; then
                    response=$(echo "$payload" | timeout "$TIMEOUT" nc -q 1 "$HOST" "$PORT" 2>/dev/null | head -1) || true
                fi
                if [[ -z "$response" ]]; then
                    response=$(curl -sf --max-time "$TIMEOUT" \
                        -H "Content-Type: application/json" \
                        -d "$payload" \
                        "http://$HOST:$PORT/rpc" 2>/dev/null) || true
                fi

                if [[ -n "$response" && "$response" == *'"result"'* ]]; then
                    check "$p health ($HOST:$PORT)" pass "healthy"
                elif [[ -n "$response" ]]; then
                    check "$p health ($HOST:$PORT)" warn "responding but unexpected format"
                else
                    check "$p health ($HOST:$PORT)" warn "TCP open, no JSON-RPC response"
                fi
            else
                check "$p health ($HOST:$PORT)" fail "not reachable"
            fi
        else
            # Local UDS probe
            FAMILY_ID="${FAMILY_ID:-$(id -u)}"
            RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
            SOCK="$RUNTIME_DIR/biomeos/${p}-${FAMILY_ID}.sock"
            SOCK_PLAIN="$RUNTIME_DIR/biomeos/${p}.sock"

            found_sock=""
            for candidate in "$SOCK" "$SOCK_PLAIN" "/tmp/biomeos/${p}.sock"; do
                if [[ -S "$candidate" ]]; then
                    found_sock="$candidate"
                    break
                fi
            done

            if [[ -z "$found_sock" ]]; then
                check "$p health (UDS)" warn "no socket found"
            else
                payload='{"jsonrpc":"2.0","method":"health.liveness","params":{},"id":1}'
                response=""
                if command -v socat >/dev/null 2>&1; then
                    response=$(echo "$payload" | timeout "$TIMEOUT" socat - "UNIX-CONNECT:$found_sock" 2>/dev/null | head -1) || true
                elif command -v nc >/dev/null 2>&1; then
                    response=$(echo "$payload" | timeout "$TIMEOUT" nc -U "$found_sock" 2>/dev/null | head -1) || true
                fi

                if [[ -n "$response" && "$response" == *'"result"'* ]]; then
                    check "$p health (UDS)" pass "healthy via $found_sock"
                elif [[ -n "$response" ]]; then
                    check "$p health (UDS)" warn "responding, unexpected format"
                else
                    check "$p health (UDS)" fail "socket exists but no response"
                fi
            fi
        fi
    done

    if ! $JSON; then echo ""; fi
fi

# =============================================================================
# Summary
# =============================================================================

if $JSON; then
    echo "{\"composition\":\"$COMPOSITION\",\"pass\":$PASS,\"warn\":$WARN,\"fail\":$FAIL,\"live\":$LIVE}"
else
    printf "${CYAN}=== Summary ===${NC}\n"
    echo "  Composition: $COMPOSITION"
    echo "  Pass: $PASS"
    echo "  Warn: $WARN"
    echo "  Fail: $FAIL"
    echo ""

    if [[ $FAIL -eq 0 && $WARN -eq 0 ]]; then
        printf "${GREEN}Composition '$COMPOSITION' is fully deployable.${NC}\n"
    elif [[ $FAIL -eq 0 ]]; then
        printf "${YELLOW}Composition '$COMPOSITION' is deployable with warnings.${NC}\n"
    else
        printf "${RED}Composition '$COMPOSITION' has failures — not ready for deploy.${NC}\n"
    fi
fi

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
