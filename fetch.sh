#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# fetch.sh — Download primal binaries from GitHub Releases and verify.
#
# Usage:
#   ./fetch.sh                    # fetch latest release
#   ./fetch.sh --tag v2026.03.24  # fetch a specific release
#   ./fetch.sh --dry-run          # show what would be downloaded
#   ./fetch.sh --help             # show this help
#
# Prerequisites:
#   - gh CLI (https://cli.github.com/) authenticated
#   - sha256sum (coreutils)

set -euo pipefail

REPO="ecoPrimals/plasmidBin"
TAG=""
DRY_RUN=false

usage() {
    sed -n '3,10p' "$0" | sed 's/^# \?//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag)    TAG="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help|-h) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

cd "$(dirname "$0")"

echo "=== plasmidBin fetch ==="
echo ""

# Determine which release to download from
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

# List available assets in the release
assets=$(gh release view "$TAG" --repo "$REPO" --json assets -q '.assets[].name' 2>/dev/null || echo "")

if [[ -z "$assets" ]]; then
    echo "ERROR: No assets found in release $TAG."
    exit 1
fi

echo "Available binaries:"
echo "$assets" | while read -r name; do
    echo "  - $name"
done
echo ""

if [[ "$DRY_RUN" == true ]]; then
    echo "(dry run — no downloads)"
    exit 0
fi

# Download each asset into a temp directory, then move to correct location
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

for asset in "$tmpdir"/*; do
    name=$(basename "$asset")

    # Skip non-binary files (metadata, manifests, etc.)
    if [[ "$name" == *.toml ]] || [[ "$name" == *.md ]] || [[ "$name" == *.lock ]]; then
        continue
    fi

    # Find the matching primal directory
    target_dir=""
    for dir in */; do
        dir="${dir%/}"
        meta="$dir/metadata.toml"
        [[ -f "$meta" ]] || continue
        primal_name=$(grep -m1 'name\s*=' "$meta" | sed 's/.*"\(.*\)".*/\1/')
        if [[ "$primal_name" == "$name" ]]; then
            target_dir="$dir"
            break
        fi
    done

    if [[ -z "$target_dir" ]]; then
        # No metadata.toml yet — create the directory
        target_dir="$name"
        mkdir -p "$target_dir"
        echo "  NEW: $name → $target_dir/"
    fi

    mv "$asset" "$target_dir/$name"
    chmod +x "$target_dir/$name"
    downloaded=$((downloaded + 1))

    # Verify checksum if metadata.toml exists
    meta="$target_dir/metadata.toml"
    if [[ -f "$meta" ]]; then
        expected=$(grep -m1 'checksum_sha256\s*=' "$meta" | sed 's/.*"\(.*\)".*/\1/')
        if [[ -n "$expected" ]]; then
            actual=$(sha256sum "$target_dir/$name" | awk '{print $1}')
            if [[ "$actual" == "$expected" ]]; then
                echo "  OK:  $name (checksum verified)"
                verified=$((verified + 1))
            else
                echo "  FAIL: $name checksum mismatch!"
                echo "    expected: $expected"
                echo "    actual:   $actual"
                failed=$((failed + 1))
            fi
        else
            echo "  WARN: $name — no checksum in metadata.toml"
        fi
    else
        echo "  WARN: $name — no metadata.toml (binary placed but unverified)"
    fi
done

echo ""
echo "=== Fetch complete ==="
echo "  Downloaded: $downloaded"
echo "  Verified:   $verified"
echo "  Failed:     $failed"

if [[ $failed -gt 0 ]]; then
    echo ""
    echo "WARNING: $failed checksum failure(s). Binaries may be corrupt or"
    echo "metadata.toml may be out of date. Run harvest.sh on the source"
    echo "machine to update checksums."
    exit 1
fi
