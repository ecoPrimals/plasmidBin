#!/usr/bin/env bash
# plasmidBin/fetch.sh — Download primal binaries from GitHub Releases
#
# Consumer script for fresh machines, remote gates, or CI pipelines.
# Downloads binaries from GitHub Releases (or a self-hosted mirror),
# validates blake3 checksums, and stages into local plasmidBin.
#
# Usage:
#   ./fetch.sh --all                    # Fetch all available binaries
#   ./fetch.sh --primal beardog         # Fetch a single primal
#   ./fetch.sh --release v2026.03.27    # Fetch from specific release tag
#   ./fetch.sh --dry-run --all          # Show what would be downloaded
#
# Prerequisites:
#   - curl
#   - b3sum (cargo install b3sum) — optional, skips checksum if missing
#   - gh (optional, for private repos; falls back to curl)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCES_FILE="$SCRIPT_DIR/sources.toml"
MANIFEST_FILE="$SCRIPT_DIR/manifest.toml"
CHECKSUMS_FILE="$SCRIPT_DIR/checksums.toml"
PRIMALS_DIR="$SCRIPT_DIR/primals"
SPRINGS_DIR="$SCRIPT_DIR/springs"
PRODUCTS_DIR="$SCRIPT_DIR/products"

GITHUB_REPO="ecoPrimals/plasmidBin"

DRY_RUN=false
FETCH_ALL=false
FORCE=false
RELEASE_TAG=""
FILTER=""

DOWNLOADED=0
SKIPPED=0
VERIFIED=0
FAILED=0
CHECKSUM_FAIL=0

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --all              Fetch all primals and springs"
    echo "  --primal NAME      Fetch a single primal/spring by name"
    echo "  --release TAG      Download from specific GitHub Release tag"
    echo "                     (default: latest release from $GITHUB_REPO)"
    echo "  --force            Re-download even if binary already exists"
    echo "  --dry-run          Show what would be downloaded, don't fetch"
    echo "  --help             Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 --all                          Fetch everything"
    echo "  $0 --primal beardog               Just beardog"
    echo "  $0 --release v2026.03.27 --all    Specific release"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)       FETCH_ALL=true; shift ;;
        --primal)    FILTER="$2"; shift 2 ;;
        --release)   RELEASE_TAG="$2"; shift 2 ;;
        --force)     FORCE=true; shift ;;
        --dry-run)   DRY_RUN=true; shift ;;
        --help)      usage; exit 0 ;;
        -*)          echo "Unknown option: $1"; usage; exit 1 ;;
        *)           FILTER="$1"; shift ;;
    esac
done

if ! $FETCH_ALL && [[ -z "$FILTER" ]]; then
    echo "ERROR: Specify --all or --primal NAME"
    echo ""
    usage
    exit 1
fi

has_b3sum() { command -v b3sum >/dev/null 2>&1; }
has_gh() { command -v gh >/dev/null 2>&1; }

detect_target_triple() {
    local machine os kernel
    machine=$(uname -m)
    kernel=$(uname -s | tr '[:upper:]' '[:lower:]')
    case "$kernel" in
        linux)
            case "$machine" in
                x86_64)  echo "x86_64-unknown-linux-musl" ;;
                aarch64) echo "aarch64-unknown-linux-musl" ;;
                armv7l)  echo "armv7-unknown-linux-musleabihf" ;;
                riscv64) echo "riscv64gc-unknown-linux-musl" ;;
                *)       echo "${machine}-unknown-linux-musl" ;;
            esac ;;
        darwin)
            case "$machine" in
                x86_64)  echo "x86_64-apple-darwin" ;;
                arm64)   echo "aarch64-apple-darwin" ;;
                *)       echo "${machine}-apple-darwin" ;;
            esac ;;
        *)  echo "${machine}-unknown-${kernel}" ;;
    esac
}

CURRENT_ARCH=$(detect_target_triple)

parse_toml_value() {
    local file="$1"
    local section="$2"
    local key="$3"
    local in_section=false
    local section_header
    section_header=$(echo "$section" | sed 's/\./\\./g')

    while IFS= read -r line; do
        if [[ "$line" =~ ^\[${section_header}\] ]]; then
            in_section=true
            continue
        fi
        if $in_section && [[ "$line" =~ ^\[ ]]; then
            break
        fi
        if $in_section && [[ "$line" =~ ^${key}[[:space:]]*=[[:space:]]*\"(.*)\" ]]; then
            echo "${BASH_REMATCH[1]}"
            return 0
        fi
        if $in_section && [[ "$line" =~ ^${key}[[:space:]]*=[[:space:]]*true ]]; then
            echo "true"
            return 0
        fi
        if $in_section && [[ "$line" =~ ^${key}[[:space:]]*=[[:space:]]*false ]]; then
            echo "false"
            return 0
        fi
    done < "$file"
    return 1
}

list_sources() {
    grep -oP '^\[sources\.(\w+)\]' "$SOURCES_FILE" | sed 's/\[sources\.//;s/\]//'
}

target_dir_for() {
    local id="$1"
    local base_dir="$PRIMALS_DIR"
    if [[ -f "$MANIFEST_FILE" ]]; then
        if parse_toml_value "$MANIFEST_FILE" "sporegarden.$id" "latest" >/dev/null 2>&1; then
            base_dir="$PRODUCTS_DIR"
        elif parse_toml_value "$MANIFEST_FILE" "springs.$id" "latest" >/dev/null 2>&1; then
            base_dir="$SPRINGS_DIR"
        fi
    fi
    echo "$base_dir/$CURRENT_ARCH"
}

binary_name_for() {
    local id="$1"
    local override
    override=$(parse_toml_value "$SOURCES_FILE" "sources.$id" "binary_name" 2>/dev/null) || true
    if [[ -n "$override" ]]; then
        echo "$override"
    else
        echo "$id"
    fi
}

get_expected_checksum() {
    local id="$1"
    local arch="$2"
    local section_prefix="primals"
    if [[ -f "$MANIFEST_FILE" ]]; then
        if parse_toml_value "$MANIFEST_FILE" "sporegarden.$id" "latest" >/dev/null 2>&1; then
            section_prefix="products"
        elif parse_toml_value "$MANIFEST_FILE" "springs.$id" "latest" >/dev/null 2>&1; then
            section_prefix="springs"
        fi
    fi
    local bin_name
    bin_name=$(binary_name_for "$id")
    parse_toml_value "$CHECKSUMS_FILE" "${section_prefix}.${bin_name}" "\"${arch}\"" 2>/dev/null || true
}

get_mirror_url() {
    parse_toml_value "$MANIFEST_FILE" "manifest" "mirror_url" 2>/dev/null || true
}

# Resolve the release tag: explicit, or latest from GitHub
resolve_release_tag() {
    if [[ -n "$RELEASE_TAG" ]]; then
        echo "$RELEASE_TAG"
        return
    fi

    if has_gh; then
        gh release view --repo "$GITHUB_REPO" --json tagName -q '.tagName' 2>/dev/null || true
    else
        local url="https://api.github.com/repos/$GITHUB_REPO/releases/latest"
        curl -sf --max-time 10 "$url" 2>/dev/null | grep -oP '"tag_name"\s*:\s*"\K[^"]+' | head -1 || true
    fi
}

# List recent release tags (up to 10) for multi-release asset search.
# Partial releases (e.g. only 4/13 primals rebuilt) are common — assets
# not found in the latest release may exist in an earlier one.
resolve_recent_tags() {
    if has_gh; then
        gh release list --repo "$GITHUB_REPO" -L 10 2>/dev/null \
            | awk '{print $NF}' \
            | grep -oP 'v\d{4}\.\d{2}\.\d{2}' || true
    else
        local url="https://api.github.com/repos/$GITHUB_REPO/releases?per_page=10"
        curl -sf --max-time 10 "$url" 2>/dev/null \
            | grep -oP '"tag_name"\s*:\s*"\K[^"]+' || true
    fi
}

download_from_release() {
    local tag="$1"
    local asset_name="$2"
    local dest="$3"

    local url="https://github.com/$GITHUB_REPO/releases/download/$tag/$asset_name"

    if $DRY_RUN; then
        echo "    [dry-run] Would download: $url"
        return 0
    fi

    if curl -sfL --max-time 300 -o "$dest" "$url" 2>/dev/null; then
        chmod +x "$dest"
        return 0
    fi

    return 1
}

download_from_mirror() {
    local mirror_url="$1"
    local asset_name="$2"
    local dest="$3"

    local url="${mirror_url%/}/$asset_name"

    if $DRY_RUN; then
        echo "    [dry-run] Would download from mirror: $url"
        return 0
    fi

    if curl -sfL --max-time 300 -o "$dest" "$url" 2>/dev/null; then
        chmod +x "$dest"
        return 0
    fi

    return 1
}

echo "plasmidBin fetch — $(date -Iseconds)"
echo "Arch: $CURRENT_ARCH"

TAG=$(resolve_release_tag)
MIRROR=$(get_mirror_url)
RECENT_TAGS=$(resolve_recent_tags)

if [[ -z "$TAG" ]]; then
    echo "WARNING: Could not resolve release tag. Trying mirror only."
fi

RECENT_COUNT=$(echo "$RECENT_TAGS" | grep -c . 2>/dev/null || echo 0)
echo "Release: ${TAG:-<none>} ($RECENT_COUNT recent releases indexed)"
if [[ -n "$MIRROR" ]]; then
    echo "Mirror:  $MIRROR"
fi
echo ""

if [[ ! -f "$SOURCES_FILE" ]]; then
    echo "ERROR: $SOURCES_FILE not found"
    exit 1
fi

mkdir -p "$PRIMALS_DIR/$CURRENT_ARCH" "$SPRINGS_DIR" "$PRODUCTS_DIR"

for source_id in $(list_sources); do
    if ! $FETCH_ALL && [[ -n "$FILTER" && "$source_id" != "$FILTER" ]]; then
        continue
    fi

    dest_dir=$(target_dir_for "$source_id")
    bin_name=$(binary_name_for "$source_id")
    local_path="$dest_dir/$bin_name"

    # genomeBin asset naming: {name}-{triple} (multi-arch releases)
    # Falls back to plain {name} for backward compatibility with older releases
    asset_name_arch="${bin_name}-${CURRENT_ARCH}"
    asset_name_plain="$bin_name"

    echo -n "  [$source_id] "

    if [[ -f "$local_path" ]] && ! $FORCE; then
        echo "EXISTS  $bin_name (use --force to re-download)"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # --force: remove stale binary so curl writes fresh
    if $FORCE && [[ -f "$local_path" ]]; then
        rm -f "$local_path"
    fi

    got_it=false
    found_tag=""

    if [[ -n "$TAG" ]]; then
        if download_from_release "$TAG" "$asset_name_arch" "$local_path"; then
            got_it=true; found_tag="$TAG"
        elif download_from_release "$TAG" "$asset_name_plain" "$local_path"; then
            got_it=true; found_tag="$TAG"
        fi
    fi

    # Search recent releases when asset is missing from the latest.
    # Partial releases are common (only rebuilt primals get new assets).
    if ! $got_it && [[ -z "$RELEASE_TAG" ]]; then
        for older_tag in $RECENT_TAGS; do
            [[ "$older_tag" == "$TAG" ]] && continue
            if download_from_release "$older_tag" "$asset_name_arch" "$local_path"; then
                got_it=true; found_tag="$older_tag"
                break
            elif download_from_release "$older_tag" "$asset_name_plain" "$local_path"; then
                got_it=true; found_tag="$older_tag"
                break
            fi
        done
        if $got_it && [[ "$found_tag" != "$TAG" ]]; then
            echo -n "(from $found_tag) "
        fi
    fi

    if ! $got_it && [[ -n "$MIRROR" ]]; then
        echo -n "(trying mirror) "
        if download_from_mirror "$MIRROR" "$asset_name_arch" "$local_path"; then
            got_it=true
        elif download_from_mirror "$MIRROR" "$asset_name_plain" "$local_path"; then
            got_it=true
        fi
    fi

    if ! $got_it; then
        echo "FAIL  could not download $bin_name (tried $asset_name_arch and $asset_name_plain across ${#RECENT_TAGS[@]:-1} releases)"
        FAILED=$((FAILED + 1))
        continue
    fi

    if $DRY_RUN; then
        echo "OK  [dry-run]"
        DOWNLOADED=$((DOWNLOADED + 1))
        continue
    fi

    if has_b3sum && [[ -f "$CHECKSUMS_FILE" ]]; then
        expected=$(get_expected_checksum "$source_id" "$CURRENT_ARCH")
        if [[ -n "$expected" ]]; then
            actual=$(b3sum --no-names "$local_path")
            if [[ "$actual" == "$expected" ]]; then
                echo "OK  checksum verified"
                VERIFIED=$((VERIFIED + 1))
            else
                echo "FAIL  checksum mismatch (removing)"
                rm -f "$local_path"
                CHECKSUM_FAIL=$((CHECKSUM_FAIL + 1))
                continue
            fi
        else
            echo "OK  (no checksum entry to verify)"
        fi
    else
        echo "OK  (checksum verification skipped)"
    fi

    DOWNLOADED=$((DOWNLOADED + 1))
done

# Create backward-compat symlinks: primals/{name} -> {triple}/{name}
# validate_composition.sh, doctor.sh, and legacy tooling expect flat primals/{name}.
if ! $DRY_RUN && [[ -d "$PRIMALS_DIR/$CURRENT_ARCH" ]]; then
    SYMLINKED=0
    for bin in "$PRIMALS_DIR/$CURRENT_ARCH"/*; do
        [[ -f "$bin" ]] || continue
        name=$(basename "$bin")
        link="$PRIMALS_DIR/$name"
        if [[ ! -e "$link" ]] || [[ -L "$link" ]]; then
            ln -sf "$CURRENT_ARCH/$name" "$link"
            SYMLINKED=$((SYMLINKED + 1))
        fi
    done
    if [[ $SYMLINKED -gt 0 ]]; then
        echo "Symlinked: $SYMLINKED (primals/{name} -> $CURRENT_ARCH/{name})"
    fi
fi

echo ""
echo "Summary:"
echo "  Downloaded: $DOWNLOADED"
echo "  Verified:   $VERIFIED"
echo "  Skipped:    $SKIPPED"
echo "  Failed:     $FAILED"
if [[ $CHECKSUM_FAIL -gt 0 ]]; then
    echo "  Checksum failures: $CHECKSUM_FAIL"
fi

if [[ $FAILED -gt 0 || $CHECKSUM_FAIL -gt 0 ]]; then
    exit 1
fi
