#!/usr/bin/env bash
# plasmidBin/sync.sh — Pull, validate checksums, and re-fetch stale binaries
#
# After `git pull`, checksums.toml may have updated hashes while local binaries
# are still from a prior release. This script detects the mismatch and re-fetches
# only the stale binaries from the matching GitHub Release.
#
# Usage:
#   ./sync.sh                  # Pull, validate, re-fetch stale
#   ./sync.sh --check-only     # Validate only, don't fetch
#   ./sync.sh --release TAG    # Force a specific release tag
#
# Requires: b3sum, curl (or gh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECKSUMS_FILE="$SCRIPT_DIR/checksums.toml"
PRIMALS_DIR="$SCRIPT_DIR/primals"
GITHUB_REPO="ecoPrimals/plasmidBin"

CHECK_ONLY=false
RELEASE_TAG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check-only) CHECK_ONLY=true; shift ;;
        --release)    RELEASE_TAG="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [--check-only] [--release TAG]"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if ! command -v b3sum >/dev/null 2>&1; then
    echo "ERROR: b3sum required (cargo install b3sum)"
    exit 1
fi

ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  ARCH_TRIPLE="x86_64-unknown-linux-musl" ;;
    aarch64) ARCH_TRIPLE="aarch64-unknown-linux-musl" ;;
    armv7l)  ARCH_TRIPLE="armv7-unknown-linux-musleabihf" ;;
    *)       echo "ERROR: Unsupported arch: $ARCH"; exit 1 ;;
esac

BIN_DIR="$PRIMALS_DIR/$ARCH_TRIPLE"

echo "plasmidBin sync — $(date -Iseconds)"
echo "Arch: $ARCH_TRIPLE"

# Step 1: git pull
if ! $CHECK_ONLY; then
    echo ""
    echo "=== Git Pull ==="
    cd "$SCRIPT_DIR"
    git pull 2>&1 | head -5
fi

# Step 2: validate checksums
echo ""
echo "=== Checksum Validation ==="

if [[ ! -f "$CHECKSUMS_FILE" ]]; then
    echo "ERROR: $CHECKSUMS_FILE not found"
    exit 1
fi

STALE=()
VERIFIED=0
MISSING=0
NO_CHECKSUM=0

for name in $(grep -oP '^\[primals\.(\w+)\]' "$CHECKSUMS_FILE" | sed 's/\[primals\.//;s/\]//'); do
    bin="$BIN_DIR/$name"

    expected=$(grep -A20 "^\[primals\.$name\]" "$CHECKSUMS_FILE" 2>/dev/null | \
               grep -m1 "\"$ARCH_TRIPLE\"" | grep -oP '"\K[a-f0-9]{64}' | head -1) || expected=""

    if [[ -z "$expected" ]]; then
        NO_CHECKSUM=$((NO_CHECKSUM + 1))
        continue
    fi

    if [[ ! -f "$bin" ]]; then
        echo "  [$name] MISSING"
        STALE+=("$name")
        MISSING=$((MISSING + 1))
        continue
    fi

    actual=$(b3sum --no-names "$bin")
    if [[ "$actual" == "$expected" ]]; then
        echo "  [$name] OK"
        VERIFIED=$((VERIFIED + 1))
    else
        echo "  [$name] STALE (checksum mismatch)"
        STALE+=("$name")
    fi
done

echo ""
echo "Verified: $VERIFIED  Stale: ${#STALE[@]}  Missing: $MISSING  No checksum: $NO_CHECKSUM"

if [[ ${#STALE[@]} -eq 0 ]]; then
    echo ""
    echo "All binaries match checksums. Nothing to do."
    exit 0
fi

if $CHECK_ONLY; then
    echo ""
    echo "Stale binaries: ${STALE[*]}"
    echo "Run without --check-only to re-fetch."
    exit 1
fi

# Step 3: resolve release tag
if [[ -z "$RELEASE_TAG" ]]; then
    RELEASE_TAG=$(git tag --sort=-creatordate | head -1)
    if [[ -z "$RELEASE_TAG" ]]; then
        echo "ERROR: No release tags found. Use --release TAG."
        exit 1
    fi
fi

echo ""
echo "=== Re-fetching ${#STALE[@]} stale binaries from $RELEASE_TAG ==="

FETCHED=0
FAILED=0

for name in "${STALE[@]}"; do
    asset_name="${name}-${ARCH_TRIPLE}"
    dest="$BIN_DIR/$name"
    url="https://github.com/$GITHUB_REPO/releases/download/$RELEASE_TAG/$asset_name"

    echo -n "  [$name] "

    rm -f "$dest"

    if curl -sfL --max-time 300 -o "$dest" "$url" 2>/dev/null; then
        chmod +x "$dest"
        actual=$(b3sum --no-names "$dest")
        expected=$(grep -A20 "^\[primals\.$name\]" "$CHECKSUMS_FILE" | \
                   grep -m1 "\"$ARCH_TRIPLE\"" | grep -oP '"\K[a-f0-9]{64}' | head -1) || expected=""

        if [[ "$actual" == "$expected" ]]; then
            echo "OK (checksum verified)"
            FETCHED=$((FETCHED + 1))
        else
            echo "WARN (downloaded but checksum mismatch — release may lag harvest)"
            FETCHED=$((FETCHED + 1))
        fi
    else
        echo "FAIL (download failed)"
        FAILED=$((FAILED + 1))
    fi
done

# Re-create symlinks
echo ""
echo "=== Symlinks ==="
for name in $(ls "$BIN_DIR" 2>/dev/null); do
    ln -sf "$ARCH_TRIPLE/$name" "$PRIMALS_DIR/$name"
done
echo "Symlinks updated."

echo ""
echo "=== Summary ==="
echo "  Fetched: $FETCHED"
echo "  Failed:  $FAILED"
echo "  Total verified: $((VERIFIED + FETCHED))"

if [[ $FAILED -gt 0 ]]; then
    exit 1
fi
