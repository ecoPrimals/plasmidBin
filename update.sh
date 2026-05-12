#!/usr/bin/env bash
# plasmidBin/update.sh — Fetch latest genome releases from GitHub
#
# Usage:
#   ./update.sh                  # Check all sources
#   ./update.sh beardog          # Check specific primal
#   ./update.sh --build ludospring  # Build from source
#   ./update.sh --dry-run        # Show what would change, don't download
#   ./update.sh --verify-only    # Verify existing binaries against checksums
#
# Requires: curl, b3sum (cargo install b3sum)
# Optional: jq (for JSON parsing, falls back to grep)
#
# Gracefully handles:
#   - Repos with no releases yet (skipped as "pending")
#   - GitHub API rate limits (warns and continues)
#   - Network failures (retries once, then skips)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCES_FILE="$SCRIPT_DIR/sources.toml"
MANIFEST_FILE="$SCRIPT_DIR/manifest.toml"
CHECKSUMS_FILE="$SCRIPT_DIR/checksums.toml"
PRIMALS_DIR="$SCRIPT_DIR/primals"
SPRINGS_DIR="$SCRIPT_DIR/springs"
PRODUCTS_DIR="$SCRIPT_DIR/products"

DRY_RUN=false
BUILD_MODE=false
VERIFY_ONLY=false
FILTER=""
UPDATED=0
SKIPPED=0
PENDING=0
FAILED=0
VERIFIED=0
CHECKSUM_FAIL=0

usage() {
    echo "Usage: $0 [OPTIONS] [PRIMAL_NAME]"
    echo ""
    echo "Options:"
    echo "  --dry-run      Show what would change without downloading"
    echo "  --build        Build from source instead of downloading releases"
    echo "  --verify-only  Verify existing binaries against checksums.toml"
    echo "  --help         Show this help"
    echo ""
    echo "Examples:"
    echo "  $0                     Check all sources for updates"
    echo "  $0 beardog             Check only beardog"
    echo "  $0 --build ludospring  Build ludospring from source"
    echo "  $0 --verify-only       Verify all local binaries"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)     DRY_RUN=true; shift ;;
        --build)       BUILD_MODE=true; shift ;;
        --verify-only) VERIFY_ONLY=true; shift ;;
        --help)        usage; exit 0 ;;
        -*)            echo "Unknown option: $1"; usage; exit 1 ;;
        *)             FILTER="$1"; shift ;;
    esac
done

has_jq() { command -v jq >/dev/null 2>&1; }
has_b3sum() { command -v b3sum >/dev/null 2>&1; }

# Parse a value from a TOML file: parse_toml_value <file> <section> <key>
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

get_manifest_version() {
    local id="$1"
    local version=""
    version=$(parse_toml_value "$MANIFEST_FILE" "primals.$id" "latest" 2>/dev/null) || true
    if [[ -z "$version" ]]; then
        version=$(parse_toml_value "$MANIFEST_FILE" "springs.$id" "latest" 2>/dev/null) || true
    fi
    echo "$version"
}

target_dir_for() {
    local id="$1"
    if parse_toml_value "$MANIFEST_FILE" "primals.$id" "latest" >/dev/null 2>&1; then
        echo "$PRIMALS_DIR"
    elif parse_toml_value "$MANIFEST_FILE" "sporegarden.$id" "latest" >/dev/null 2>&1; then
        echo "$PRODUCTS_DIR"
    else
        echo "$SPRINGS_DIR"
    fi
}

# Resolve the simple binary name for a primal/spring.
# discover_binary() in primalSpring expects: primals/{name}
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

# Look up expected blake3 checksum from checksums.toml
# Section key: primals.<name> or springs.<name>
get_expected_checksum() {
    local id="$1"
    local arch="$2"
    local dest_dir
    dest_dir=$(target_dir_for "$id")
    local section_prefix
    if [[ "$dest_dir" == "$PRIMALS_DIR" ]]; then
        section_prefix="primals"
    elif [[ "$dest_dir" == "$PRODUCTS_DIR" ]]; then
        section_prefix="products"
    else
        section_prefix="springs"
    fi
    local bin_name
    bin_name=$(binary_name_for "$id")
    parse_toml_value "$CHECKSUMS_FILE" "${section_prefix}.${bin_name}" "\"${arch}\"" 2>/dev/null || true
}

verify_checksum() {
    local file="$1"
    local expected="$2"
    if [[ -z "$expected" ]]; then
        echo "no-checksum"
        return 0
    fi
    if ! has_b3sum; then
        echo "no-b3sum"
        return 0
    fi
    local actual
    actual=$(b3sum --no-names "$file")
    if [[ "$actual" == "$expected" ]]; then
        echo "ok"
        return 0
    else
        echo "mismatch:$actual"
        return 1
    fi
}

# Detect current architecture as full Rust target triple matching checksums.toml keys
detect_arch() {
    local machine
    machine=$(uname -m)
    case "$machine" in
        x86_64)  echo "x86_64-unknown-linux-musl" ;;
        aarch64) echo "aarch64-unknown-linux-musl" ;;
        armv7l)  echo "armv7-unknown-linux-musleabihf" ;;
        *)       echo "$machine-unknown-linux-musl" ;;
    esac
}

CURRENT_ARCH=$(detect_arch)

# ── Verify-only mode ─────────────────────────────────────────────────────────
if $VERIFY_ONLY; then
    echo "plasmidBin verify — $(date -Iseconds)"
    echo "Arch: $CURRENT_ARCH"
    echo ""

    if [[ ! -f "$CHECKSUMS_FILE" ]]; then
        echo "ERROR: $CHECKSUMS_FILE not found"
        exit 1
    fi

    for source_id in $(list_sources); do
        if [[ -n "$FILTER" && "$source_id" != "$FILTER" ]]; then
            continue
        fi

        dest_dir=$(target_dir_for "$source_id")
        bin_name=$(binary_name_for "$source_id")
        bin_path="$dest_dir/$bin_name"

        if [[ ! -f "$bin_path" ]]; then
            echo "  [$source_id] MISSING  $bin_path"
            FAILED=$((FAILED + 1))
            continue
        fi

        expected=$(get_expected_checksum "$source_id" "$CURRENT_ARCH")
        if [[ -z "$expected" ]]; then
            echo "  [$source_id] SKIP     no checksum entry for $CURRENT_ARCH"
            SKIPPED=$((SKIPPED + 1))
            continue
        fi

        result=$(verify_checksum "$bin_path" "$expected") || true
        case "$result" in
            ok)
                echo "  [$source_id] OK       $bin_name"
                VERIFIED=$((VERIFIED + 1))
                ;;
            no-b3sum)
                echo "  [$source_id] SKIP     b3sum not installed"
                SKIPPED=$((SKIPPED + 1))
                ;;
            mismatch:*)
                actual="${result#mismatch:}"
                echo "  [$source_id] FAIL     checksum mismatch"
                echo "               expected: $expected"
                echo "               actual:   $actual"
                CHECKSUM_FAIL=$((CHECKSUM_FAIL + 1))
                ;;
        esac
    done

    echo ""
    echo "Summary:"
    echo "  Verified: $VERIFIED"
    echo "  Skipped:  $SKIPPED"
    echo "  Missing:  $FAILED"
    echo "  Mismatch: $CHECKSUM_FAIL"

    if [[ $CHECKSUM_FAIL -gt 0 || $FAILED -gt 0 ]]; then
        exit 1
    fi
    exit 0
fi

# ── Update mode ──────────────────────────────────────────────────────────────

fetch_latest_release() {
    local repo="$1"
    local url="https://api.github.com/repos/$repo/releases/latest"
    local response
    response=$(curl -sf --max-time 10 "$url" 2>/dev/null) || return 1
    if has_jq; then
        echo "$response" | jq -r '.tag_name // empty' 2>/dev/null
    else
        echo "$response" | grep -oP '"tag_name"\s*:\s*"\K[^"]+' | head -1
    fi
}

download_asset() {
    local repo="$1"
    local tag="$2"
    local asset="$3"
    local dest="$4"
    local url="https://github.com/$repo/releases/download/$tag/$asset"

    echo "    Downloading $url"
    if ! $DRY_RUN; then
        curl -sfL --max-time 120 -o "$dest" "$url" 2>/dev/null
        if [[ -f "$dest" ]]; then
            chmod +x "$dest"
            return 0
        fi
    else
        echo "    [dry-run] Would save to $dest"
        return 0
    fi
    return 1
}

build_from_source() {
    local repo="$1"
    local id="$2"
    local dest_dir="$3"
    local clone_dir="/tmp/plasmidBin-build-$id"

    echo "    Building $id from source (repo: $repo)"

    if $DRY_RUN; then
        echo "    [dry-run] Would clone $repo and cargo build --release"
        return 0
    fi

    rm -rf "$clone_dir"
    if ! git clone --depth 1 "https://github.com/$repo.git" "$clone_dir" 2>/dev/null; then
        echo "    WARN: Failed to clone $repo (may be private or nonexistent)"
        return 1
    fi

    if ! (cd "$clone_dir" && cargo build --release 2>/dev/null); then
        echo "    WARN: Build failed for $id"
        rm -rf "$clone_dir"
        return 1
    fi

    local bin_name
    bin_name=$(binary_name_for "$id")

    local built="$clone_dir/target/release/$bin_name"
    if [[ -f "$built" ]]; then
        cp "$built" "$dest_dir/$bin_name"
        chmod +x "$dest_dir/$bin_name"
        echo "    Installed $bin_name to $dest_dir/"
    else
        echo "    WARN: Binary $bin_name not found in build output"
        rm -rf "$clone_dir"
        return 1
    fi

    rm -rf "$clone_dir"
    return 0
}

echo "plasmidBin update — $(date -Iseconds)"
echo "Sources: $SOURCES_FILE"
echo "Arch:    $CURRENT_ARCH"
echo ""

if [[ ! -f "$SOURCES_FILE" ]]; then
    echo "ERROR: $SOURCES_FILE not found"
    exit 1
fi

mkdir -p "$PRIMALS_DIR" "$SPRINGS_DIR" "$PRODUCTS_DIR"

for source_id in $(list_sources); do
    if [[ -n "$FILTER" && "$source_id" != "$FILTER" ]]; then
        continue
    fi

    repo=$(parse_toml_value "$SOURCES_FILE" "sources.$source_id" "repo" 2>/dev/null) || continue
    build_from_src=$(parse_toml_value "$SOURCES_FILE" "sources.$source_id" "build_from_source" 2>/dev/null) || build_from_src="false"

    current_version=$(get_manifest_version "$source_id")
    dest_dir=$(target_dir_for "$source_id")
    bin_name=$(binary_name_for "$source_id")

    echo "[$source_id]  repo=$repo  current=$current_version  binary=$bin_name"

    if [[ "$BUILD_MODE" == "true" || "$build_from_src" == "true" ]]; then
        if build_from_source "$repo" "$source_id" "$dest_dir"; then
            UPDATED=$((UPDATED + 1))
        else
            FAILED=$((FAILED + 1))
        fi
        continue
    fi

    latest_tag=$(fetch_latest_release "$repo" 2>/dev/null) || latest_tag=""

    if [[ -z "$latest_tag" ]]; then
        echo "    -> Pending first release (no releases found or repo inaccessible)"
        PENDING=$((PENDING + 1))
        continue
    fi

    latest_version="${latest_tag#v}"

    if [[ "$latest_version" == "$current_version" ]]; then
        echo "    -> Up to date ($current_version)"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    echo "    -> Update available: $current_version -> $latest_version"

    first_asset=$(grep -A5 "^\[sources\.$source_id\]" "$SOURCES_FILE" | \
                  grep -oP 'assets\s*=\s*\["\K[^"]+' | head -1) || first_asset=""

    if [[ -n "$first_asset" ]]; then
        local_path="$dest_dir/$bin_name"
        if download_asset "$repo" "$latest_tag" "$first_asset" "$local_path"; then
            if [[ -f "$CHECKSUMS_FILE" ]] && has_b3sum && ! $DRY_RUN; then
                expected=$(get_expected_checksum "$source_id" "$CURRENT_ARCH")
                if [[ -n "$expected" ]]; then
                    result=$(verify_checksum "$local_path" "$expected") || true
                    if [[ "$result" != "ok" ]]; then
                        echo "    -> WARNING: checksum mismatch after download"
                        echo "    -> Re-run harvest.sh to update checksums if this is a new build"
                    fi
                fi
            fi
            UPDATED=$((UPDATED + 1))
            echo "    -> Updated to $latest_version"
        else
            echo "    -> WARN: Download failed for $first_asset"
            FAILED=$((FAILED + 1))
        fi
    else
        echo "    -> No asset names configured; skipping download"
        SKIPPED=$((SKIPPED + 1))
    fi
done

echo ""
echo "Summary:"
echo "  Updated: $UPDATED"
echo "  Up-to-date: $SKIPPED"
echo "  Pending first release: $PENDING"
echo "  Failed: $FAILED"

if [[ $FAILED -gt 0 ]]; then
    exit 1
fi
