#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# fetch.sh — Download primal binaries from GitHub Releases and verify.
#
# Usage:
#   ./fetch.sh                    # fetch latest release for local arch
#   ./fetch.sh --tag v2026.03.24  # fetch a specific release
#   ./fetch.sh --arch aarch64     # fetch for a different architecture
#   ./fetch.sh --dry-run          # show what would be downloaded
#   ./fetch.sh --help             # show this help
#
# Architecture is auto-detected from `uname -m`. Override with --arch.
# Checksums are verified against the [builds.<arch>-linux] section of
# each primal's metadata.toml.
#
# Prerequisites:
#   - gh CLI (https://cli.github.com/) authenticated
#   - sha256sum (coreutils)

set -euo pipefail

REPO="ecoPrimals/plasmidBin"
TAG=""
DRY_RUN=false
ARCH=""

usage() {
    sed -n '3,12p' "$0" | sed 's/^# \?//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag)     TAG="$2"; shift 2 ;;
        --arch)    ARCH="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help|-h) usage ;;
        *)         echo "Unknown option: $1"; usage ;;
    esac
done

cd "$(dirname "$0")"

# ── Detect architecture ──────────────────────────────────────────────
if [[ -z "$ARCH" ]]; then
    raw_arch=$(uname -m)
    case "$raw_arch" in
        x86_64|amd64)    ARCH="x86_64" ;;
        aarch64|arm64)   ARCH="aarch64" ;;
        armv7l|armhf)    ARCH="armv7" ;;
        riscv64)         ARCH="riscv64" ;;
        *)               ARCH="$raw_arch" ;;
    esac
fi

BUILDS_KEY="${ARCH}-linux"

echo "=== plasmidBin fetch ==="
echo "Architecture: $ARCH ($BUILDS_KEY)"
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
    echo "ERROR: No assets found in release $TAG."
    exit 1
fi

echo "Available binaries in release:"
echo "$assets" | while read -r name; do
    echo "  - $name"
done
echo ""

if [[ "$DRY_RUN" == true ]]; then
    echo "(dry run — no downloads)"
    exit 0
fi

# ── Download all assets ──────────────────────────────────────────────
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

echo "--- Downloading ---"
gh release download "$TAG" \
    --repo "$REPO" \
    --pattern '*' \
    --dir "$tmpdir" \
    --clobber

echo ""
echo "--- Placing binaries ---"

downloaded=0
verified=0
failed=0
skipped=0

for asset in "$tmpdir"/*; do
    name=$(basename "$asset")

    # Skip non-binary files
    if [[ "$name" == *.toml ]] || [[ "$name" == *.md ]] || [[ "$name" == *.lock ]] || [[ "$name" == *.sh ]] || [[ "$name" == *.env ]]; then
        continue
    fi

    # Find the matching primal directory by checking metadata.toml [primal].name
    target_dir=""
    for dir in */; do
        dir="${dir%/}"
        meta="$dir/metadata.toml"
        [[ -f "$meta" ]] || continue
        primal_name=$(grep -m1 '^name\s*=' "$meta" | sed 's/.*"\(.*\)".*/\1/')
        if [[ "$primal_name" == "$name" ]]; then
            target_dir="$dir"
            break
        fi
    done

    # Also try matching directory name directly (for assets named like the dir)
    if [[ -z "$target_dir" ]] && [[ -d "$name" ]] && [[ -f "$name/metadata.toml" ]]; then
        target_dir="$name"
    fi

    if [[ -z "$target_dir" ]]; then
        target_dir="$name"
        mkdir -p "$target_dir"
        echo "  NEW: $name → $target_dir/"
    fi

    mv "$asset" "$target_dir/$name"
    chmod +x "$target_dir/$name"
    downloaded=$((downloaded + 1))

    # Verify checksum against [builds.<arch>-linux].checksum_sha256
    meta="$target_dir/metadata.toml"
    if [[ -f "$meta" ]]; then
        # Try arch-specific checksum first (new format: [builds.x86_64-linux])
        expected=""
        in_builds_section=false
        while IFS= read -r line; do
            if [[ "$line" =~ ^\[builds\.${BUILDS_KEY}\] ]]; then
                in_builds_section=true
                continue
            fi
            if $in_builds_section && [[ "$line" =~ ^\[ ]]; then
                break
            fi
            if $in_builds_section && [[ "$line" =~ checksum_sha256 ]]; then
                expected=$(echo "$line" | sed 's/.*"\(.*\)".*/\1/')
                break
            fi
        done < "$meta"

        # Fallback: try legacy [provenance].checksum_sha256
        if [[ -z "$expected" ]]; then
            expected=$(grep -m1 'checksum_sha256\s*=' "$meta" | sed 's/.*"\(.*\)".*/\1/' || true)
        fi

        if [[ -n "$expected" ]]; then
            actual=$(sha256sum "$target_dir/$name" | awk '{print $1}')
            if [[ "$actual" == "$expected" ]]; then
                echo "  OK:  $name ($BUILDS_KEY checksum verified)"
                verified=$((verified + 1))
            else
                echo "  FAIL: $name checksum mismatch!"
                echo "    expected: $expected"
                echo "    actual:   $actual"
                failed=$((failed + 1))
            fi
        else
            echo "  WARN: $name — no checksum for $BUILDS_KEY in metadata.toml"
        fi
    else
        echo "  WARN: $name — no metadata.toml (binary placed but unverified)"
    fi
done

echo ""
echo "=== Fetch complete ==="
echo "  Architecture: $ARCH"
echo "  Downloaded:   $downloaded"
echo "  Verified:     $verified"
echo "  Failed:       $failed"

if [[ $failed -gt 0 ]]; then
    echo ""
    echo "WARNING: $failed checksum failure(s). Binaries may be corrupt or"
    echo "metadata.toml may be out of date. Run harvest.sh on the source"
    echo "machine to update checksums."
    exit 1
fi
