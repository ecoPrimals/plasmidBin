#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# fetch.sh — Download primal binaries from GitHub Releases and verify.
#
# Usage:
#   ./fetch.sh                        # fetch latest release for local arch
#   ./fetch.sh beardog songbird       # fetch specific primals only
#   ./fetch.sh --tag v2026.04.01      # fetch a specific release
#   ./fetch.sh --arch aarch64         # fetch for a different architecture
#   ./fetch.sh --composition tower    # fetch all primals in a composition
#   ./fetch.sh --dry-run              # show what would be downloaded
#   ./fetch.sh --help                 # show this help
#
# Architecture is auto-detected from `uname -m`. Override with --arch.
# Checksums are verified against the [builds.<arch>-linux] section of
# each primal's metadata.toml.
#
# Prerequisites:
#   - gh CLI (https://cli.github.com/) authenticated  OR
#   - curl (fallback — downloads from release URL directly)
#   - sha256sum (coreutils)

set -euo pipefail

REPO="ecoPrimals/plasmidBin"
TAG=""
DRY_RUN=false
ARCH=""
COMPOSITION=""
TARGETS=()
MAX_RETRIES=3
RETRY_DELAY=5

usage() {
    sed -n '3,14p' "$0" | sed 's/^# \?//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag)         TAG="$2"; shift 2 ;;
        --arch)        ARCH="$2"; shift 2 ;;
        --composition) COMPOSITION="$2"; shift 2 ;;
        --dry-run)     DRY_RUN=true; shift ;;
        --help|-h)     usage ;;
        -*)            echo "Unknown option: $1"; usage ;;
        *)             TARGETS+=("$1"); shift ;;
    esac
done

cd "$(dirname "$0")"

# ── Detect architecture ──────────────────────────────────────────────
if [[ -z "$ARCH" ]]; then
    raw_arch=$(uname -m)
    case "$raw_arch" in
        x86_64|amd64)   ARCH="x86_64" ;;
        aarch64|arm64)  ARCH="aarch64" ;;
        armv7l|armhf)   ARCH="armv7" ;;
        riscv64)        ARCH="riscv64" ;;
        *)              ARCH="$raw_arch" ;;
    esac
fi

BUILDS_KEY="${ARCH}-linux"

echo "=== plasmidBin fetch ==="
echo "Architecture: $ARCH ($BUILDS_KEY)"

# ── Resolve composition to primal list ───────────────────────────────
if [[ -n "$COMPOSITION" ]]; then
    if [[ -f "ports.env" ]]; then
        source ports.env
        comp_list=$(primals_for_composition "$COMPOSITION" 2>/dev/null || echo "")
        if [[ -z "$comp_list" ]]; then
            echo "ERROR: Unknown composition '$COMPOSITION'"
            echo "Available: tower, compute, node, nest, full, provenance, science"
            exit 1
        fi
        # shellcheck disable=SC2206
        TARGETS=($comp_list)
        echo "Composition: $COMPOSITION → ${TARGETS[*]}"
    else
        echo "ERROR: ports.env not found — cannot resolve composition"
        exit 1
    fi
fi

echo ""

# ── Determine release ────────────────────────────────────────────────
if [[ -n "$TAG" ]]; then
    echo "Release: $TAG (specified)"
else
    TAG=$(gh release view --repo "$REPO" --json tagName -q '.tagName' 2>/dev/null || echo "")
    if [[ -z "$TAG" ]]; then
        echo "ERROR: No releases found on $REPO."
        echo "The maintainer needs to run harvest.sh first."
        exit 1
    fi
    echo "Release: $TAG (latest)"
fi

echo ""

# ── List available assets ────────────────────────────────────────────
assets=$(gh release view "$TAG" --repo "$REPO" --json assets -q '.assets[].name' 2>/dev/null || echo "")

if [[ -z "$assets" ]]; then
    echo "WARNING: No assets in release $TAG."
    echo "Metadata is available; binaries must be fetched from another source"
    echo "or built from source."
    exit 0
fi

echo "Available assets in release $TAG:"
echo "$assets" | while read -r name; do
    echo "  - $name"
done
echo ""

# ── Helper: retry a command ──────────────────────────────────────────
retry() {
    local attempt=1
    while [[ $attempt -le $MAX_RETRIES ]]; do
        if "$@"; then
            return 0
        fi
        echo "  Retry $attempt/$MAX_RETRIES in ${RETRY_DELAY}s..."
        sleep "$RETRY_DELAY"
        attempt=$((attempt + 1))
    done
    return 1
}

# ── Helper: should we fetch this primal? ─────────────────────────────
should_fetch() {
    local name="$1"
    if [[ ${#TARGETS[@]} -eq 0 ]]; then
        return 0
    fi
    for t in "${TARGETS[@]}"; do
        [[ "$t" == "$name" ]] && return 0
    done
    return 1
}

# ── Helper: extract checksum from metadata.toml ─────────────────────
get_expected_checksum() {
    local meta="$1" builds_key="$2"
    local in_section=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^\[builds\.${builds_key}\] ]]; then
            in_section=true
            continue
        fi
        if $in_section && [[ "$line" =~ ^\[ ]]; then
            break
        fi
        if $in_section && [[ "$line" =~ checksum_sha256[[:space:]]*= ]]; then
            echo "$line" | sed 's/.*"\(.*\)".*/\1/'
            return
        fi
    done < "$meta"
}

if [[ "$DRY_RUN" == true ]]; then
    echo "--- Dry run: would download ---"
fi

# ── Download per-primal ──────────────────────────────────────────────

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

downloaded=0
verified=0
failed=0
skipped=0
missing=0

for dir in */; do
    dir="${dir%/}"
    meta="$dir/metadata.toml"
    [[ -f "$meta" ]] || continue

    name=$(grep -m1 'name\s*=' "$meta" | sed 's/.*"\(.*\)".*/\1/')
    [[ -z "$name" ]] && continue

    should_fetch "$name" || continue

    # Check if this primal has a build for our arch
    if ! grep -q "\[builds\.${BUILDS_KEY}\]" "$meta"; then
        echo "SKIP: $name — no $BUILDS_KEY build defined in metadata.toml"
        skipped=$((skipped + 1))
        continue
    fi

    # Try arch-suffixed asset name first (new convention), then bare name (legacy)
    asset_name=""
    if echo "$assets" | grep -qx "${name}-${ARCH}"; then
        asset_name="${name}-${ARCH}"
    elif echo "$assets" | grep -qx "${name}"; then
        asset_name="${name}"
    fi

    if [[ -z "$asset_name" ]]; then
        echo "MISS: $name — no asset matching '${name}-${ARCH}' or '${name}' in release"
        missing=$((missing + 1))
        continue
    fi

    version=$(grep -m1 'version\s*=' "$meta" | sed 's/.*"\(.*\)".*/\1/')

    if [[ "$DRY_RUN" == true ]]; then
        echo "  $name v$version ← $asset_name"
        continue
    fi

    echo "FETCH: $name v$version ← $asset_name"

    # Download single asset
    if ! retry gh release download "$TAG" \
        --repo "$REPO" \
        --pattern "$asset_name" \
        --dir "$tmpdir" \
        --clobber 2>/dev/null; then
        echo "  ERROR: Failed to download $asset_name after $MAX_RETRIES attempts"
        failed=$((failed + 1))
        continue
    fi

    # Place binary (always stored as the bare primal name locally)
    mv "$tmpdir/$asset_name" "$dir/$name"
    chmod +x "$dir/$name"
    downloaded=$((downloaded + 1))

    # Verify checksum
    expected=$(get_expected_checksum "$meta" "$BUILDS_KEY")
    if [[ -n "$expected" ]]; then
        actual=$(sha256sum "$dir/$name" | awk '{print $1}')
        if [[ "$actual" == "$expected" ]]; then
            echo "  OK: checksum verified"
            verified=$((verified + 1))
        else
            echo "  FAIL: checksum mismatch!"
            echo "    expected: $expected"
            echo "    actual:   $actual"
            echo "    The binary may be corrupt or metadata.toml is stale."
            failed=$((failed + 1))
        fi
    else
        echo "  WARN: no checksum for $BUILDS_KEY — binary unverified"
    fi
done

echo ""
echo "=== Fetch complete ==="
echo "  Architecture: $ARCH ($BUILDS_KEY)"
echo "  Downloaded:   $downloaded"
echo "  Verified:     $verified"
echo "  Skipped:      $skipped (no build for this arch)"
echo "  Missing:      $missing (no release asset)"
echo "  Failed:       $failed"

if [[ $failed -gt 0 ]]; then
    echo ""
    echo "WARNING: $failed failure(s). Check output above."
    exit 1
fi

if [[ $downloaded -eq 0 ]] && [[ "$DRY_RUN" == false ]]; then
    echo ""
    echo "No binaries downloaded. Either:"
    echo "  - No release assets match your architecture ($ARCH)"
    echo "  - The maintainer hasn't harvested yet (run harvest.sh)"
    echo "  - Specify primals: ./fetch.sh beardog songbird"
fi
