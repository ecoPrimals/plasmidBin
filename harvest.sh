#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# harvest.sh — Build checksums, update metadata, create GitHub Release.
#
# Usage:
#   ./harvest.sh                        # harvest all primals with binaries present
#   ./harvest.sh beardog songbird       # harvest specific primals only
#   ./harvest.sh --tag v2026.04.01      # use a specific release tag
#   ./harvest.sh --arch aarch64         # override architecture detection
#   ./harvest.sh --dry-run              # show what would happen without doing it
#   ./harvest.sh --no-release           # update metadata only, skip GitHub Release
#   ./harvest.sh --help                 # show this help
#
# Prerequisites:
#   - gh CLI (https://cli.github.com/) authenticated
#   - sha256sum (coreutils)
#   - Primal binaries already built with --remap-path-prefix and strip=true
#     (see wateringHole SECRETS_AND_SEEDS_STANDARD.md)
#
# Asset naming convention:
#   Binaries are uploaded as {name}-{arch} (e.g. beardog-x86_64, beardog-aarch64).
#   This allows a single release to carry builds for multiple architectures.

set -euo pipefail

REPO="ecoPrimals/plasmidBin"
TAG=""
DRY_RUN=false
NO_RELEASE=false
ARCH=""
TARGETS=()
MAX_RETRIES=3
RETRY_DELAY=5

usage() {
    sed -n '3,16p' "$0" | sed 's/^# \?//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag)        TAG="$2"; shift 2 ;;
        --arch)       ARCH="$2"; shift 2 ;;
        --dry-run)    DRY_RUN=true; shift ;;
        --no-release) NO_RELEASE=true; shift ;;
        --help|-h)    usage ;;
        -*)           echo "Unknown option: $1"; usage ;;
        *)            TARGETS+=("$1"); shift ;;
    esac
done

cd "$(dirname "$0")"

# ── Detect architecture ──────────────────────────────────────────────
if [[ -z "$ARCH" ]]; then
    raw_arch=$(uname -m)
    case "$raw_arch" in
        x86_64|amd64)   ARCH="x86_64" ;;
        aarch64|arm64)  ARCH="aarch64" ;;
        *)              ARCH="$raw_arch" ;;
    esac
fi

BUILDS_KEY="${ARCH}-linux"

if [[ -z "$TAG" ]]; then
    TAG="v$(date +%Y.%m.%d)"
fi

echo "=== plasmidBin harvest ==="
echo "Architecture: $ARCH ($BUILDS_KEY)"
echo "Tag:          $TAG"
echo ""

# ── Helper: update a key inside a specific TOML section ──────────────
# Usage: update_toml_key <file> <section> <key> <value>
# Updates key=value inside [section], or appends if missing.
update_toml_key() {
    local file="$1" section="$2" key="$3" value="$4"
    local tmp="${file}.tmp"
    local in_section=false
    local key_written=false

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^\[${section}\] ]]; then
            in_section=true
            echo "$line"
            continue
        fi

        if $in_section && [[ "$line" =~ ^\[ ]]; then
            if ! $key_written; then
                echo "${key} = \"${value}\""
                key_written=true
            fi
            in_section=false
        fi

        if $in_section && [[ "$line" =~ ^#?[[:space:]]*${key}[[:space:]]*= ]]; then
            echo "${key} = \"${value}\""
            key_written=true
            continue
        fi

        echo "$line"
    done < "$file" > "$tmp"

    if $in_section && ! $key_written; then
        echo "${key} = \"${value}\"" >> "$tmp"
    fi

    mv "$tmp" "$file"
}

# ── Helper: retry a command ──────────────────────────────────────────
retry() {
    local attempt=1
    while [[ $attempt -le $MAX_RETRIES ]]; do
        if "$@"; then
            return 0
        fi
        echo "  Attempt $attempt/$MAX_RETRIES failed. Retrying in ${RETRY_DELAY}s..."
        sleep "$RETRY_DELAY"
        attempt=$((attempt + 1))
    done
    echo "  ERROR: Command failed after $MAX_RETRIES attempts: $*"
    return 1
}

# ── Collect binaries ─────────────────────────────────────────────────

binaries=()
asset_args=()
notes_lines=()

should_harvest() {
    local name="$1"
    if [[ ${#TARGETS[@]} -eq 0 ]]; then
        return 0
    fi
    for t in "${TARGETS[@]}"; do
        [[ "$t" == "$name" ]] && return 0
    done
    return 1
}

for dir in */; do
    dir="${dir%/}"
    meta="$dir/metadata.toml"
    [[ -f "$meta" ]] || continue

    name=$(grep -m1 'name\s*=' "$meta" | sed 's/.*"\(.*\)".*/\1/')
    [[ -z "$name" ]] && continue

    should_harvest "$name" || continue

    bin="$dir/$name"
    if [[ ! -f "$bin" ]]; then
        echo "SKIP: $name — no binary at $bin"
        continue
    fi

    if [[ ! -x "$bin" ]]; then
        chmod +x "$bin"
    fi

    checksum=$(sha256sum "$bin" | awk '{print $1}')
    version=$(grep -m1 'version\s*=' "$meta" | sed 's/.*"\(.*\)".*/\1/')
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    size=$(du -h "$bin" | awk '{print $1}')

    echo "HARVEST: $name v$version ($size)"
    echo "  binary:   $bin"
    echo "  arch:     $BUILDS_KEY"
    echo "  checksum: $checksum"

    # Verify the binary has no build-machine paths baked in
    if strings "$bin" 2>/dev/null | grep -qE '/home/(east|west|south|north|strand|biome)gate'; then
        echo "  WARNING: Binary contains build-machine paths!"
        echo "           Rebuild with --remap-path-prefix before harvesting."
        echo "           See wateringHole SECRETS_AND_SEEDS_STANDARD.md"
    fi

    if [[ "$DRY_RUN" == false ]]; then
        update_toml_key "$meta" "builds\\.${BUILDS_KEY}" "checksum_sha256" "$checksum"

        if grep -q 'built_at' "$meta"; then
            sed -i "s/^built_at = .*/built_at = \"$timestamp\"/" "$meta"
        fi
    fi

    # Release asset: name with arch suffix for multi-arch coexistence
    asset_name="${name}-${ARCH}"
    cp "$bin" "/tmp/$asset_name"
    binaries+=("$bin")
    asset_args+=("/tmp/$asset_name")
    notes_lines+=("- **$name** v$version — $ARCH ($size)")
done

if [[ ${#binaries[@]} -eq 0 ]]; then
    echo ""
    echo "No primal binaries found to harvest."
    echo "Build primals first, then copy binaries into their directories:"
    echo "  cp target/release/beardog plasmidBin/beardog/"
    exit 1
fi

# ── Regenerate manifest.lock ─────────────────────────────────────────

echo ""
echo "--- Generating manifest.lock ---"

if [[ "$DRY_RUN" == false ]]; then
    gen_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    {
        cat <<LOCKHEADER
# plasmidBin manifest.lock — Resolved primal versions for this deployment
# Generated: $gen_ts
# Source: local builds

[meta]
generated = "$gen_ts"
registry_version = "3.0.0"
tag = "$TAG"
architectures = ["x86_64-linux", "aarch64-linux"]
LOCKHEADER

        for dir in */; do
            dir="${dir%/}"
            meta="$dir/metadata.toml"
            [[ -f "$meta" ]] || continue

            name=$(grep -m1 'name\s*=' "$meta" | sed 's/.*"\(.*\)".*/\1/')
            [[ -z "$name" ]] && continue

            version=$(grep -m1 'version\s*=' "$meta" | sed 's/.*"\(.*\)".*/\1/')
            domain=$(grep -m1 'domain\s*=' "$meta" | sed 's/.*"\(.*\)".*/\1/' 2>/dev/null || echo "unknown")
            tier=$(grep -m1 'tier\s*=' "$meta" | sed 's/.*"\(.*\)".*/\1/' 2>/dev/null || echo "ecoBin")

            # Determine default port from ports.env
            port_var="${name^^}_PORT"
            port_var="${port_var//-/_}"

            # Collect available builds
            builds=""
            if grep -q "\[builds\.x86_64-linux\]" "$meta"; then
                builds="${builds:+$builds, }\"x86_64-linux\""
            fi
            if grep -q "\[builds\.aarch64-linux\]" "$meta"; then
                builds="${builds:+$builds, }\"aarch64-linux\""
            fi

            # Categorize as primal or spring
            category="primals"
            case "$name" in
                *spring*) category="springs" ;;
            esac

            echo ""
            echo "[$category.$name]"
            echo "version = \"$version\""
            echo "domain = \"$domain\""
            echo "tier = \"$tier\""
            [[ -n "$builds" ]] && echo "builds = [$builds]"
        done

        # Compositions (read from ports.env)
        echo ""
        echo "# ── Compositions ─────────────────────────────────────────────────────"
        echo ""
        echo "[compositions.tower]"
        echo "primals = [\"beardog\", \"songbird\"]"
        echo ""
        echo "[compositions.compute]"
        echo "primals = [\"beardog\", \"songbird\", \"toadstool\"]"
        echo ""
        echo "[compositions.node]"
        echo "primals = [\"beardog\", \"songbird\", \"toadstool\", \"squirrel\"]"
        echo ""
        echo "[compositions.nest]"
        echo "primals = [\"beardog\", \"songbird\", \"nestgate\"]"
        echo ""
        echo "[compositions.full]"
        echo "primals = [\"beardog\", \"songbird\", \"nestgate\", \"toadstool\", \"squirrel\", \"biomeos\", \"petaltongue\"]"
        echo ""
        echo "[compositions.provenance]"
        echo "primals = [\"beardog\", \"songbird\", \"rhizocrypt\", \"loamspine\", \"sweetgrass\"]"
        echo ""
        echo "[compositions.science]"
        echo "primals = [\"beardog\", \"songbird\", \"toadstool\", \"squirrel\", \"biomeos\"]"
    } > manifest.lock

    echo "  manifest.lock regenerated"
fi

# ── Create GitHub Release ────────────────────────────────────────────

echo ""
echo "--- Release summary ---"
echo "Tag:      $TAG"
echo "Arch:     $ARCH"
echo "Binaries: ${#binaries[@]}"
for line in "${notes_lines[@]}"; do
    echo "  $line"
done

if [[ "$DRY_RUN" == true ]]; then
    echo ""
    echo "(dry run — no changes made)"
    rm -f /tmp/*-"${ARCH}" 2>/dev/null || true
    exit 0
fi

if [[ "$NO_RELEASE" == true ]]; then
    echo ""
    echo "(--no-release — metadata updated, no GitHub Release created)"
else
    echo ""
    echo "--- Creating GitHub Release ---"

    release_notes=$(printf '%s\n' "${notes_lines[@]}")

    # Check if release already exists — if so, upload assets to it
    if gh release view "$TAG" --repo "$REPO" &>/dev/null; then
        echo "  Release $TAG exists — uploading new assets"
        retry gh release upload "$TAG" \
            "${asset_args[@]}" \
            --repo "$REPO" \
            --clobber
    else
        retry gh release create "$TAG" \
            "${asset_args[@]}" \
            --repo "$REPO" \
            --title "Harvest $TAG" \
            --notes "$release_notes"
    fi

    echo "  Release: https://github.com/$REPO/releases/tag/$TAG"
fi

# ── Cleanup temp files ───────────────────────────────────────────────
rm -f /tmp/*-"${ARCH}" 2>/dev/null || true

# ── Commit metadata ──────────────────────────────────────────────────

echo ""
echo "--- Committing metadata ---"

git add manifest.lock */metadata.toml
git commit -m "harvest($ARCH): $TAG — ${#binaries[@]} binaries" || echo "(nothing to commit)"

echo ""
echo "Done. Run 'git push' to publish metadata."
