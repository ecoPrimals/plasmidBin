#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# harvest.sh — Build checksums, update metadata, create GitHub Release.
#
# Usage:
#   ./harvest.sh                  # harvest all primals with binaries present
#   ./harvest.sh --tag v2026.03.25  # use a specific release tag
#   ./harvest.sh --dry-run        # show what would happen without doing it
#   ./harvest.sh --help           # show this help
#
# Prerequisites:
#   - gh CLI (https://cli.github.com/) authenticated
#   - sha256sum (coreutils)
#   - Primal binaries already copied into their directories

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

if [[ -z "$TAG" ]]; then
    TAG="v$(date +%Y.%m.%d)"
fi

cd "$(dirname "$0")"

binaries=()
notes_lines=()

for dir in */; do
    dir="${dir%/}"
    meta="$dir/metadata.toml"
    [[ -f "$meta" ]] || continue

    name=$(grep -m1 'name\s*=' "$meta" | sed 's/.*"\(.*\)".*/\1/')
    [[ -z "$name" ]] && continue

    bin="$dir/$name"
    if [[ ! -f "$bin" ]]; then
        echo "SKIP: $dir — no binary at $bin"
        continue
    fi

    checksum=$(sha256sum "$bin" | awk '{print $1}')
    version=$(grep -m1 'version\s*=' "$meta" | sed 's/.*"\(.*\)".*/\1/')
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    echo "HARVEST: $name v$version ($bin)"
    echo "  checksum: $checksum"

    if [[ "$DRY_RUN" == false ]]; then
        # Update checksum in metadata.toml
        sed -i "s/^checksum_sha256 = .*/checksum_sha256 = \"$checksum\"/" "$meta"

        # Update built_at timestamp in metadata.toml
        if grep -q 'built_at' "$meta"; then
            sed -i "s/^built_at = .*/built_at = \"$timestamp\"/" "$meta"
        fi
    fi

    binaries+=("$bin")
    notes_lines+=("- **$name** v$version ($(du -h "$bin" | awk '{print $1}'))")
done

if [[ ${#binaries[@]} -eq 0 ]]; then
    echo "No primal binaries found to harvest."
    exit 1
fi

echo ""
echo "--- Generating manifest.lock ---"

if [[ "$DRY_RUN" == false ]]; then
    cat > manifest.lock << LOCKHEADER
# plasmidBin manifest.lock — Resolved primal versions for this deployment
# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Source: local builds

[meta]
generated = "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
registry_version = "2.0.0"
tag = "$TAG"
LOCKHEADER

    for dir in */; do
        dir="${dir%/}"
        meta="$dir/metadata.toml"
        [[ -f "$meta" ]] || continue

        name=$(grep -m1 'name\s*=' "$meta" | sed 's/.*"\(.*\)".*/\1/')
        [[ -z "$name" ]] && continue
        [[ -f "$dir/$name" ]] || continue

        version=$(grep -m1 'version\s*=' "$meta" | sed 's/.*"\(.*\)".*/\1/')
        arch=$(grep -m1 'architecture\s*=' "$meta" | sed 's/.*"\(.*\)".*/\1/' || echo "x86_64-linux")
        checksum=$(sha256sum "$dir/$name" | awk '{print $1}')
        domain=$(grep -m1 'domain\s*=' "$meta" | sed 's/.*"\(.*\)".*/\1/' || echo "unknown")

        cat >> manifest.lock << ENTRY

[primals.$name]
version = "$version"
architecture = "$arch"
checksum_sha256 = "$checksum"
path = "$dir/$name"
domain = "$domain"
ENTRY
    done

    echo "  manifest.lock updated"
fi

echo ""
echo "--- Release summary ---"
echo "Tag: $TAG"
echo "Binaries: ${#binaries[@]}"
for line in "${notes_lines[@]}"; do
    echo "  $line"
done

if [[ "$DRY_RUN" == true ]]; then
    echo ""
    echo "(dry run — no changes made)"
    exit 0
fi

echo ""
echo "--- Creating GitHub Release ---"

release_notes=$(printf '%s\n' "${notes_lines[@]}")

gh release create "$TAG" \
    "${binaries[@]}" \
    --repo "$REPO" \
    --title "Harvest $TAG" \
    --notes "$release_notes"

echo ""
echo "--- Committing metadata ---"

git add manifest.lock */metadata.toml
git commit -m "harvest: $TAG" || echo "(nothing to commit)"

echo ""
echo "Done. Run 'git push' to publish metadata."
echo "Release: https://github.com/$REPO/releases/tag/$TAG"
