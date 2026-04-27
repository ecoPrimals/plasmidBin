#!/usr/bin/env bash
# plasmidBin/doctor.sh — Health check for plasmidBin installation
#
# Verifies prerequisites, binary inventory, ecoBin compliance,
# checksum integrity, and deployment readiness.
#
# Usage:
#   ./doctor.sh              # Full check
#   ./doctor.sh --quick      # Prerequisites + inventory only (no checksums)
#   ./doctor.sh --json       # Machine-readable output

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

QUICK=false
JSON=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --quick) QUICK=true; shift ;;
        --json)  JSON=true; shift ;;
        --help)
            echo "Usage: $0 [--quick] [--json]"
            echo "  --quick   Skip checksum verification"
            echo "  --json    Machine-readable JSON output"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
WARN=0
FAIL=0

check() {
    local label="$1"
    local status="$2"
    local detail="${3:-}"

    case "$status" in
        pass)
            PASS=$((PASS + 1))
            if ! $JSON; then printf "  ${GREEN}OK${NC}   %s" "$label"; fi
            ;;
        warn)
            WARN=$((WARN + 1))
            if ! $JSON; then printf "  ${YELLOW}WARN${NC} %s" "$label"; fi
            ;;
        fail)
            FAIL=$((FAIL + 1))
            if ! $JSON; then printf "  ${RED}FAIL${NC} %s" "$label"; fi
            ;;
    esac
    if ! $JSON && [[ -n "$detail" ]]; then
        echo "  ($detail)"
    elif ! $JSON; then
        echo ""
    fi
}

if ! $JSON; then
    echo "plasmidBin doctor — $(date -Iseconds)"
    echo ""
fi

# ── Prerequisites ────────────────────────────────────────────────────────────

if ! $JSON; then echo "=== Prerequisites ==="; fi

if command -v b3sum >/dev/null 2>&1; then
    check "b3sum" pass "$(b3sum --version 2>/dev/null | head -1)"
else
    check "b3sum" fail "install: cargo install b3sum"
fi

if command -v curl >/dev/null 2>&1; then
    check "curl" pass
else
    check "curl" fail "required for fetch.sh and update.sh"
fi

if command -v gh >/dev/null 2>&1; then
    check "gh (GitHub CLI)" pass
else
    check "gh (GitHub CLI)" warn "optional — fetch.sh falls back to curl"
fi

if command -v adb >/dev/null 2>&1; then
    check "adb" pass
    if adb get-state >/dev/null 2>&1; then
        check "adb device" pass "$(adb get-serialno 2>/dev/null)"
    else
        check "adb device" warn "no device connected"
    fi
else
    check "adb" warn "optional — needed for deploy_pixel.sh"
fi

if command -v strip >/dev/null 2>&1; then
    check "strip" pass
else
    check "strip" warn "needed for harvest.sh"
fi

if command -v nc >/dev/null 2>&1; then
    check "nc (netcat)" pass
else
    check "nc (netcat)" warn "needed for validate_gate.sh raw TCP probes"
fi

if ! $JSON; then echo ""; fi

# ── Metadata files ───────────────────────────────────────────────────────────

if ! $JSON; then echo "=== Metadata ==="; fi

for f in manifest.toml sources.toml checksums.toml ports.env; do
    if [[ -f "$SCRIPT_DIR/$f" ]]; then
        check "$f" pass
    else
        check "$f" fail "missing"
    fi
done

if ! $JSON; then echo ""; fi

# ── Binary inventory ─────────────────────────────────────────────────────────

if ! $JSON; then echo "=== Binary Inventory (x86_64) ==="; fi

X86_COUNT=0
X86_ECOBIN=0
for name in beardog songbird nestgate toadstool barracuda coralreef squirrel petaltongue biomeos rhizocrypt loamspine sweetgrass skunkbat; do
    bin="$SCRIPT_DIR/primals/$name"
    if [[ ! -f "$bin" ]]; then
        check "$name" fail "missing"
        continue
    fi
    X86_COUNT=$((X86_COUNT + 1))

    file_out=$(file "$bin" 2>/dev/null)
    is_static=false
    is_stripped=false
    if echo "$file_out" | grep -qE "statically linked|static-pie"; then is_static=true; fi
    if ! echo "$file_out" | grep -q "not stripped"; then is_stripped=true; fi

    sz=$(du -h "$bin" | cut -f1)

    if $is_static && $is_stripped; then
        check "$name" pass "${sz}, static, stripped"
        X86_ECOBIN=$((X86_ECOBIN + 1))
    elif $is_static; then
        check "$name" warn "${sz}, static, NOT stripped"
    else
        check "$name" fail "${sz}, DYNAMIC — not ecoBin"
    fi
done

if ! $JSON; then echo ""; echo "=== Binary Inventory (aarch64) ==="; fi

ARM_COUNT=0
ARM_ECOBIN=0
for name in beardog songbird squirrel toadstool biomeos barracuda coralreef; do
    bin="$SCRIPT_DIR/primals/aarch64/$name"
    if [[ ! -f "$bin" ]]; then
        check "$name (aarch64)" warn "not built yet"
        continue
    fi
    ARM_COUNT=$((ARM_COUNT + 1))

    file_out=$(file "$bin" 2>/dev/null)
    is_static=false
    is_stripped=false
    if echo "$file_out" | grep -q "statically linked"; then is_static=true; fi
    if ! echo "$file_out" | grep -q "not stripped"; then is_stripped=true; fi

    sz=$(du -h "$bin" | cut -f1)

    if $is_static && $is_stripped; then
        check "$name (aarch64)" pass "${sz}, static, stripped"
        ARM_ECOBIN=$((ARM_ECOBIN + 1))
    elif $is_static; then
        check "$name (aarch64)" warn "${sz}, static, NOT stripped"
    else
        check "$name (aarch64)" fail "${sz}, DYNAMIC — not ecoBin"
    fi
done

if ! $JSON; then echo ""; fi

# ── Coordination primal ──────────────────────────────────────────────────────

if ! $JSON; then echo "=== Coordination Primal ==="; fi

bin="$SCRIPT_DIR/primals/primalspring_primal"
if [[ -f "$bin" ]]; then
    file_out=$(file "$bin" 2>/dev/null)
    is_static=false
    is_stripped=false
    if echo "$file_out" | grep -qE "statically linked|static-pie"; then is_static=true; fi
    if ! echo "$file_out" | grep -q "not stripped"; then is_stripped=true; fi
    sz=$(du -h "$bin" | cut -f1)
    if $is_static && $is_stripped; then
        check "primalspring_primal" pass "${sz}, static, stripped"
    elif $is_static; then
        check "primalspring_primal" warn "${sz}, static, NOT stripped"
    else
        check "primalspring_primal" warn "${sz}, dynamic"
    fi
else
    check "primalspring_primal" warn "not built yet"
fi

if ! $JSON; then echo ""; fi

# Springs do NOT ship binaries via plasmidBin. They validate science by
# composing the primals above. See manifest.toml [niches] for composition
# requirements per spring.

# ── Atomic composition validation ────────────────────────────────────────────
# Verify that all primals for each NUCLEUS atomic are present

if ! $JSON; then echo "=== Atomic Composition Validation ==="; fi

PRIMALS_DIR="$SCRIPT_DIR/primals"
# Phase 31 atomic definitions
ATOMIC_TOWER="beardog songbird"
ATOMIC_NODE="beardog songbird toadstool barracuda coralreef"
ATOMIC_NEST="beardog songbird nestgate rhizocrypt loamspine sweetgrass"
ATOMIC_META="biomeos squirrel petaltongue"

check_atomic() {
    local name="$1"
    shift
    local primals=("$@")
    local present=0
    local total=${#primals[@]}
    local missing_list=""

    for p in "${primals[@]}"; do
        if [[ -f "$PRIMALS_DIR/$p" ]]; then
            present=$((present + 1))
        else
            missing_list+=" $p"
        fi
    done

    if [[ $present -eq $total ]]; then
        check "$name ($present/$total)" pass
    elif [[ $present -gt 0 ]]; then
        check "$name ($present/$total)" warn "missing:$missing_list"
    else
        check "$name ($present/$total)" fail "no primals present"
    fi
}

check_atomic "Tower (electron)" $ATOMIC_TOWER
check_atomic "Node (proton)" $ATOMIC_NODE
check_atomic "Nest (neutron)" $ATOMIC_NEST
check_atomic "Meta-tier" $ATOMIC_META

NUCLEUS_PRIMALS="beardog songbird toadstool barracuda coralreef nestgate rhizocrypt loamspine sweetgrass"
check_atomic "NUCLEUS (atom)" $NUCLEUS_PRIMALS

if ! $JSON; then echo ""; fi

# ── Checksum verification ────────────────────────────────────────────────────

if ! $QUICK && command -v b3sum >/dev/null 2>&1 && [[ -f "$SCRIPT_DIR/checksums.toml" ]]; then
    if ! $JSON; then echo "=== Checksum Verification ==="; fi

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  ARCH_TRIPLE="x86_64-linux-musl" ;;
        aarch64) ARCH_TRIPLE="aarch64-linux-musl" ;;
        *)       ARCH_TRIPLE="$ARCH-linux-musl" ;;
    esac

    CHECKSUMS_VERIFIED=0
    CHECKSUMS_FAILED=0

    GNU_TRIPLE="${ARCH}-linux-gnu"

    for name in beardog songbird toadstool barracuda coralreef nestgate rhizocrypt loamspine sweetgrass biomeos squirrel petaltongue skunkbat primalspring_primal; do
        bin="$SCRIPT_DIR/primals/$name"
        [[ ! -f "$bin" ]] && continue

        section="primals.$name"
        expected=$(grep -A2 "^\[$section\]" "$SCRIPT_DIR/checksums.toml" 2>/dev/null | \
                   grep "\"$ARCH_TRIPLE\"" | grep -oP '"\K[a-f0-9]{64}' | head -1) || expected=""

        # Fallback to glibc triple (trio primals ship glibc until musl-static)
        if [[ -z "$expected" ]]; then
            expected=$(grep -A2 "^\[$section\]" "$SCRIPT_DIR/checksums.toml" 2>/dev/null | \
                       grep "\"$GNU_TRIPLE\"" | grep -oP '"\K[a-f0-9]{64}' | head -1) || expected=""
        fi

        if [[ -z "$expected" ]]; then
            check "$name checksum" warn "no entry for $ARCH_TRIPLE or $GNU_TRIPLE"
            continue
        fi

        actual=$(b3sum --no-names "$bin")
        if [[ "$actual" == "$expected" ]]; then
            check "$name checksum" pass
            CHECKSUMS_VERIFIED=$((CHECKSUMS_VERIFIED + 1))
        else
            check "$name checksum" fail "mismatch"
            CHECKSUMS_FAILED=$((CHECKSUMS_FAILED + 1))
        fi
    done

    if ! $JSON; then echo ""; fi
fi

# ── Summary ──────────────────────────────────────────────────────────────────

if $JSON; then
    echo "{\"pass\":$PASS,\"warn\":$WARN,\"fail\":$FAIL,\"x86_64_count\":$X86_COUNT,\"x86_64_ecobin\":$X86_ECOBIN,\"aarch64_count\":$ARM_COUNT,\"aarch64_ecobin\":$ARM_ECOBIN}"
else
    echo "=== Summary ==="
    echo "  Pass: $PASS"
    echo "  Warn: $WARN"
    echo "  Fail: $FAIL"
    echo ""
    echo "  x86_64 primals: $X86_COUNT binaries ($X86_ECOBIN ecoBin)"
    echo "  aarch64 primals: $ARM_COUNT binaries ($ARM_ECOBIN ecoBin)"
    echo ""

    if [[ $FAIL -eq 0 && $WARN -eq 0 ]]; then
        printf "${GREEN}plasmidBin is healthy.${NC}\n"
    elif [[ $FAIL -eq 0 ]]; then
        printf "${YELLOW}plasmidBin is functional with warnings.${NC}\n"
    else
        printf "${RED}plasmidBin has issues that need attention.${NC}\n"
    fi
fi

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
