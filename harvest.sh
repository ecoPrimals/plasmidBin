#!/usr/bin/env bash
# plasmidBin/harvest.sh — Publish local binaries to plasmidBin + GitHub Releases
#
# Takes freshly built musl static binaries, validates them, computes checksums,
# copies to local plasmidBin/{primals,springs}/, and optionally uploads to
# GitHub Releases.
#
# Usage:
#   ./harvest.sh                              # Harvest x86_64 from default staging
#   ./harvest.sh --arch aarch64               # Harvest aarch64 binaries
#   ./harvest.sh --source /path/to/bins       # Harvest from custom dir
#   ./harvest.sh --release v2026.03.27        # Also upload to GitHub Release
#   ./harvest.sh --dry-run                    # Validate only, no file changes
#   ./harvest.sh --primal beardog             # Harvest a single primal
#
# Default source: /tmp/primalspring-deploy/primals/{arch}/
#
# Multi-arch layout:
#   plasmidBin/primals/beardog              (x86_64 — default, backward compat)
#   plasmidBin/primals/aarch64/beardog      (aarch64)
#
# Prerequisites:
#   - b3sum (cargo install b3sum)
#   - strip (binutils, or aarch64 strip for cross-arch)
#   - file (for ELF/static checks)
#   - gh (GitHub CLI, only for --release)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECKSUMS_FILE="$SCRIPT_DIR/checksums.toml"
PRIMALS_DIR="$SCRIPT_DIR/primals"
SPRINGS_DIR="$SCRIPT_DIR/springs"

GITHUB_REPO="ecoPrimals/plasmidBin"

DRY_RUN=false
RELEASE_TAG=""
FILTER=""
ARCH=""
SOURCE_DIR=""

HARVESTED=0
SKIPPED=0
FAILED=0

# Harvest maps keyed by arch. Format: "artifact-name:category/local-name"
# artifact-name matches build_ecosystem_musl.sh output: {binary}-{arch}-linux-musl
# Harvest maps: PRIMALS ONLY.
# Springs do not ship binaries via plasmidBin — they compose primals.
# The only exception is primalspring_primal (coordination primal).
# Core primal names — used to auto-generate harvest maps for any target triple.
CORE_PRIMAL_NAMES=(beardog songbird toadstool barracuda coralreef nestgate rhizocrypt loamspine sweetgrass biomeos squirrel petaltongue skunkbat primalspring_primal)

# Legacy harvest maps kept for backward compatibility with old --arch x86_64/aarch64
HARVEST_MAP_X86_64=()
HARVEST_MAP_AARCH64=()
for p in "${CORE_PRIMAL_NAMES[@]}"; do
    HARVEST_MAP_X86_64+=("${p}-x86_64-linux-musl:primals/x86_64-unknown-linux-musl/${p}")
    HARVEST_MAP_AARCH64+=("${p}-aarch64-linux-musl:primals/aarch64-unknown-linux-musl/${p}")
done

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --source DIR       Source directory for built binaries"
    echo "  --arch ARCH        Target architecture: x86_64 (default) or aarch64"
    echo "  --release TAG      Upload to GitHub Release with this tag"
    echo "  --primal NAME      Harvest only this primal (e.g., beardog)"
    echo "  --dry-run          Validate binaries without copying or uploading"
    echo "  --help             Show this help"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source)    SOURCE_DIR="$2"; shift 2 ;;
        --arch)      ARCH="$2"; shift 2 ;;
        --release)   RELEASE_TAG="$2"; shift 2 ;;
        --primal)    FILTER="$2"; shift 2 ;;
        --dry-run)   DRY_RUN=true; shift ;;
        --help)      usage; exit 0 ;;
        -*)          echo "Unknown option: $1"; usage; exit 1 ;;
        *)           FILTER="$1"; shift ;;
    esac
done

detect_arch() {
    local machine
    machine=$(uname -m)
    case "$machine" in
        x86_64)  echo "x86_64" ;;
        aarch64) echo "aarch64" ;;
        armv7l)  echo "armv7" ;;
        *)       echo "$machine" ;;
    esac
}

# Resolve ARCH to a full target triple. Accepts both short names (x86_64) and
# full triples (x86_64-unknown-linux-musl).
resolve_target_triple() {
    case "$1" in
        x86_64)                          echo "x86_64-unknown-linux-musl" ;;
        aarch64)                         echo "aarch64-unknown-linux-musl" ;;
        armv7)                           echo "armv7-unknown-linux-musleabihf" ;;
        riscv64)                         echo "riscv64gc-unknown-linux-musl" ;;
        *-unknown-*|*-apple-*|*-linux-*|*-pc-*|wasm32-*) echo "$1" ;; # already a full triple
        *)                               echo "$1-unknown-linux-musl" ;;
    esac
}

if [[ -z "$ARCH" ]]; then
    ARCH=$(detect_arch)
fi

ARCH_TRIPLE=$(resolve_target_triple "$ARCH")

if [[ -z "$SOURCE_DIR" ]]; then
    # Try target-triple layout first, fall back to short arch name
    if [[ -d "/tmp/primalspring-deploy/primals/$ARCH_TRIPLE" ]]; then
        SOURCE_DIR="/tmp/primalspring-deploy/primals/$ARCH_TRIPLE"
    else
        SOURCE_DIR="/tmp/primalspring-deploy/primals/$ARCH"
    fi
fi

# Build harvest map for the target. For known legacy short names, use the
# pre-built maps. For any target triple, build dynamically.
case "$ARCH" in
    x86_64)  HARVEST_MAP=("${HARVEST_MAP_X86_64[@]}") ;;
    aarch64) HARVEST_MAP=("${HARVEST_MAP_AARCH64[@]}") ;;
    *)
        # Dynamic harvest map for arbitrary target triples
        HARVEST_MAP=()
        for p in "${CORE_PRIMAL_NAMES[@]}"; do
            HARVEST_MAP+=("${p}:primals/${ARCH_TRIPLE}/${p}")
        done
        ;;
esac

is_static_elf() {
    local bin="$1"
    if ! file "$bin" | grep -q "ELF"; then
        return 1
    fi
    # For cross-arch binaries, ldd won't work — check file output instead
    if file "$bin" | grep -q "statically linked"; then
        return 0
    fi
    local ldd_out
    ldd_out=$(ldd "$bin" 2>&1) || true
    if echo "$ldd_out" | grep -qE "statically linked|not a dynamic executable"; then
        return 0
    fi
    return 1
}

# Select strip binary — cross-arch needs cross-strip
select_strip() {
    case "$ARCH_TRIPLE" in
        aarch64-unknown-linux-musl|aarch64-linux-*)
            if command -v aarch64-linux-gnu-strip >/dev/null 2>&1; then
                echo "aarch64-linux-gnu-strip"
            else echo ""; fi ;;
        armv7-*)
            if command -v arm-linux-gnueabihf-strip >/dev/null 2>&1; then
                echo "arm-linux-gnueabihf-strip"
            else echo ""; fi ;;
        riscv64*)
            if command -v riscv64-linux-gnu-strip >/dev/null 2>&1; then
                echo "riscv64-linux-gnu-strip"
            else echo ""; fi ;;
        x86_64-pc-windows-gnu)
            if command -v x86_64-w64-mingw32-strip >/dev/null 2>&1; then
                echo "x86_64-w64-mingw32-strip"
            else echo ""; fi ;;
        *)
            echo "strip" ;;
    esac
}

STRIP_BIN=$(select_strip)

update_checksum() {
    local section="$1"
    local arch="$2"
    local hash="$3"
    local tmpfile
    tmpfile=$(mktemp)

    if [[ ! -f "$CHECKSUMS_FILE" ]]; then
        cat > "$CHECKSUMS_FILE" <<HEADER
# plasmidBin checksums — blake3
#
# One entry per binary, keyed by target triple.
# Validated by update.sh, harvest.sh, and fetch.sh.
#
# Updated: $(date -I)

HEADER
    fi

    local in_section=false
    local section_header
    section_header=$(echo "$section" | sed 's/\./\\./g')
    local key_written=false
    local section_found=false

    while IFS= read -r line; do
        if [[ "$line" =~ ^\[${section_header}\] ]]; then
            in_section=true
            section_found=true
            echo "$line" >> "$tmpfile"
            continue
        fi
        if $in_section && [[ "$line" =~ ^\[ ]]; then
            if ! $key_written; then
                echo "\"$arch\" = \"$hash\"" >> "$tmpfile"
                key_written=true
            fi
            in_section=false
        fi
        if $in_section && [[ "$line" =~ ^\"${arch}\" ]]; then
            echo "\"$arch\" = \"$hash\"" >> "$tmpfile"
            key_written=true
            continue
        fi
        echo "$line" >> "$tmpfile"
    done < "$CHECKSUMS_FILE"

    if $in_section && ! $key_written; then
        echo "\"$arch\" = \"$hash\"" >> "$tmpfile"
    fi

    if ! $section_found; then
        echo "" >> "$tmpfile"
        echo "[$section]" >> "$tmpfile"
        echo "\"$arch\" = \"$hash\"" >> "$tmpfile"
    fi

    mv "$tmpfile" "$CHECKSUMS_FILE"
}

echo "plasmidBin harvest — $(date -Iseconds)"
echo "Source:  $SOURCE_DIR"
echo "Arch:    $ARCH ($ARCH_TRIPLE)"
if [[ -n "$RELEASE_TAG" ]]; then
    echo "Release: $RELEASE_TAG (-> $GITHUB_REPO)"
fi
echo ""

if [[ ! -d "$SOURCE_DIR" ]]; then
    echo "ERROR: Source directory not found: $SOURCE_DIR"
    echo "  Run build_ecosystem_musl.sh first to produce binaries."
    exit 1
fi

mkdir -p "$PRIMALS_DIR/$ARCH_TRIPLE" "$SPRINGS_DIR"

RELEASE_ASSETS=()

for entry in "${HARVEST_MAP[@]}"; do
    artifact="${entry%%:*}"
    dest_rel="${entry##*:}"
    local_name=$(basename "$dest_rel")
    category=$(dirname "$dest_rel")

    if [[ -n "$FILTER" && "$local_name" != "$FILTER" && "$artifact" != *"$FILTER"* ]]; then
        continue
    fi

    src="$SOURCE_DIR/$artifact"
    if [[ ! -f "$src" ]]; then
        echo "  [$local_name] SKIP  artifact not found: $artifact"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    echo -n "  [$local_name] "

    if ! is_static_elf "$src"; then
        echo "FAIL  not a static ELF binary"
        FAILED=$((FAILED + 1))
        continue
    fi

    local_dest="$SCRIPT_DIR/$dest_rel"
    stripped_tmp=$(mktemp)
    if [[ -n "$STRIP_BIN" ]]; then
        "$STRIP_BIN" -s "$src" -o "$stripped_tmp" 2>/dev/null || cp "$src" "$stripped_tmp"
    else
        cp "$src" "$stripped_tmp"
        echo -n "(no cross-strip) "
    fi
    chmod +x "$stripped_tmp"

    hash=$(b3sum --no-names "$stripped_tmp")
    size=$(du -h "$stripped_tmp" | cut -f1)

    if $DRY_RUN; then
        echo "OK  [dry-run] static, stripped, ${size}, blake3=$hash"
        rm -f "$stripped_tmp"
        HARVESTED=$((HARVESTED + 1))
        continue
    fi

    cp "$stripped_tmp" "$local_dest"

    # Checksum section: primals.{name} or springs.{name} — arch is the key, not part of section
    case "$dest_rel" in
        primals/*) checksum_section="primals.${local_name}" ;;
        springs/*) checksum_section="springs.${local_name}" ;;
        *)         checksum_section="primals.${local_name}" ;;
    esac
    update_checksum "$checksum_section" "$ARCH_TRIPLE" "$hash"

    RELEASE_ASSETS+=("$local_dest")

    echo "OK  ${size}  blake3=${hash:0:16}..."
    HARVESTED=$((HARVESTED + 1))

    rm -f "$stripped_tmp"
done

echo ""

if [[ -n "$RELEASE_TAG" ]] && [[ ${#RELEASE_ASSETS[@]} -gt 0 ]] && ! $DRY_RUN; then
    echo "Publishing to GitHub Release: $RELEASE_TAG"

    if ! command -v gh >/dev/null 2>&1; then
        echo "  ERROR: gh (GitHub CLI) not installed. Skipping release upload."
        echo "  Install: https://cli.github.com/"
    else
        existing=$(gh release view "$RELEASE_TAG" --repo "$GITHUB_REPO" 2>/dev/null) || true
        if [[ -z "$existing" ]]; then
            echo "  Creating release $RELEASE_TAG ..."
            gh release create "$RELEASE_TAG" \
                --repo "$GITHUB_REPO" \
                --title "plasmidBin $RELEASE_TAG" \
                --notes "Automated harvest — $(date -I)" \
                "${RELEASE_ASSETS[@]}"
        else
            echo "  Uploading to existing release $RELEASE_TAG ..."
            gh release upload "$RELEASE_TAG" \
                --repo "$GITHUB_REPO" \
                --clobber \
                "${RELEASE_ASSETS[@]}"
        fi
        echo "  Done."
    fi
fi

echo ""
echo "Summary:"
echo "  Harvested: $HARVESTED"
echo "  Skipped:   $SKIPPED"
echo "  Failed:    $FAILED"

if [[ $FAILED -gt 0 ]]; then
    exit 1
fi
