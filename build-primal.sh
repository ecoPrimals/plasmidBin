#!/usr/bin/env bash
# plasmidBin/build-primal.sh — Clone, build, and stage a single primal (or all)
#
# Used by auto-harvest CI and locally. Reads sources.toml for repo mappings,
# clones shallow, builds musl static release, stages to /tmp/primalspring-deploy/.
#
# Usage:
#   ./build-primal.sh biomeos              # Build one primal
#   ./build-primal.sh --all                # Build all 13 primals
#   ./build-primal.sh biomeos --harvest    # Build + harvest into plasmidBin
#   ./build-primal.sh --all --harvest --release v2026.04.29
#
# Prerequisites:
#   - rustup, cargo
#   - musl-tools (apt install musl-tools)
#   - rustup target add x86_64-unknown-linux-musl
#   - gh CLI (for private repos, uses GITHUB_TOKEN or gh auth)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCES_FILE="$SCRIPT_DIR/sources.toml"
STAGING="/tmp/primalspring-deploy"
BUILD_ROOT="/tmp/primalspring-build"

TARGET="x86_64-unknown-linux-musl"
BUILD_ALL=false
DO_HARVEST=false
RELEASE_TAG=""
FILTER=""

passed=0
failed=0
failed_private=0
skipped=0

usage() {
    echo "Usage: $0 [PRIMAL|--all] [OPTIONS]"
    echo ""
    echo "Arguments:"
    echo "  PRIMAL             Primal ID from sources.toml (e.g., biomeos, beardog)"
    echo "  --all              Build all primals in sources.toml"
    echo ""
    echo "Options:"
    echo "  --target TRIPLE    Rust target triple (default: x86_64-unknown-linux-musl)"
    echo "  --harvest          Run harvest.sh after building"
    echo "  --release TAG      Pass release tag to harvest.sh (implies --harvest)"
    echo "  --help             Show this help"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)       BUILD_ALL=true; shift ;;
        --target)    TARGET="$2"; shift 2 ;;
        --harvest)   DO_HARVEST=true; shift ;;
        --release)   RELEASE_TAG="$2"; DO_HARVEST=true; shift 2 ;;
        --help|-h)   usage; exit 0 ;;
        -*)          echo "Unknown option: $1"; usage; exit 1 ;;
        *)           FILTER="$1"; shift ;;
    esac
done

if ! $BUILD_ALL && [[ -z "$FILTER" ]]; then
    echo "ERROR: Specify a primal name or --all"
    usage
    exit 1
fi

if [[ ! -f "$SOURCES_FILE" ]]; then
    echo "ERROR: $SOURCES_FILE not found"
    exit 1
fi

parse_toml_value() {
    local file="$1" section="$2" key="$3"
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
    done < "$file"
    return 1
}

list_sources() {
    grep -oP '^\[sources\.(\w+)\]' "$SOURCES_FILE" | sed 's/\[sources\.//;s/\]//'
}

arch_short() {
    case "$TARGET" in
        x86_64-*)  echo "x86_64" ;;
        aarch64-*) echo "aarch64" ;;
        armv7-*)   echo "armv7" ;;
        *)         echo "${TARGET%%-*}" ;;
    esac
}

ARCH=$(arch_short)

build_one() {
    local id="$1"
    local repo binary_name is_private

    repo=$(parse_toml_value "$SOURCES_FILE" "sources.$id" "repo" 2>/dev/null) || true
    binary_name=$(parse_toml_value "$SOURCES_FILE" "sources.$id" "binary_name" 2>/dev/null) || true
    is_private=$(parse_toml_value "$SOURCES_FILE" "sources.$id" "private" 2>/dev/null) || true
    build_args=$(parse_toml_value "$SOURCES_FILE" "sources.$id" "build_args" 2>/dev/null) || true
    needs_sibling=$(parse_toml_value "$SOURCES_FILE" "sources.$id" "needs_sibling" 2>/dev/null) || true

    if [[ -z "$repo" ]]; then
        echo "  [$id] SKIP  no repo in sources.toml"
        ((skipped++)) || true
        return
    fi

    local clone_dir="$BUILD_ROOT/$id"
    local out_dir="$STAGING/primals/$TARGET"
    mkdir -p "$out_dir"

    echo -n "  [$id] cloning $repo"
    [[ "$is_private" == "true" ]] && echo -n " (private)"
    echo " ..."

    rm -rf "$clone_dir"

    # Clone sibling repos if needed (e.g., skunkBat needs sourDough)
    if [[ -n "$needs_sibling" ]]; then
        local sibling_name="${needs_sibling##*/}"
        local sibling_dir="$BUILD_ROOT/$sibling_name"
        if [[ ! -d "$sibling_dir" ]]; then
            echo "  [$id] cloning sibling $needs_sibling ..."
            git clone --depth 1 "https://github.com/${needs_sibling}.git" "$sibling_dir" 2>/dev/null || true
        fi
    fi

    if ! git clone --depth 1 "https://github.com/${repo}.git" "$clone_dir" 2>/tmp/build_clone_${id}.log; then
        if [[ "$is_private" == "true" ]]; then
            echo "  [$id] SKIP  private repo clone failed (PAT may lack access)"
            ((failed_private++)) || true
        else
            echo "  [$id] FAIL  clone failed (see /tmp/build_clone_${id}.log)"
            ((failed++)) || true
        fi
        return
    fi

    echo "  [$id] building for $TARGET ..."

    # shellcheck disable=SC2086
    if ! cargo build --release --target "$TARGET" \
        --manifest-path "$clone_dir/Cargo.toml" \
        $build_args \
        2>"/tmp/build_cargo_${id}.log"; then
        echo "  [$id] FAIL  build failed (see /tmp/build_cargo_${id}.log)"
        ((failed++)) || true
        return
    fi

    local bin_dir="$clone_dir/target/$TARGET/release"
    local copied=0

    # If binary_name override exists, look for that specifically
    if [[ -n "$binary_name" ]]; then
        local src="$bin_dir/$binary_name"
        if [[ -f "$src" ]] && file "$src" | grep -q "ELF"; then
            cp "$src" "$out_dir/${binary_name}-${ARCH}-linux-musl"
            ((copied++)) || true
        fi
    fi

    # Also scan for ELF binaries matching the primal id
    for bin in "$bin_dir"/*; do
        [[ -f "$bin" ]] && [[ -x "$bin" ]] && [[ ! -d "$bin" ]] || continue
        local bn
        bn="$(basename "$bin")"
        case "$bn" in
            *.d|*.rlib|*.rmeta|*.so|build-script-*|*.a) continue ;;
        esac
        if file "$bin" | grep -q "ELF"; then
            local dest_name="${bn}-${ARCH}-linux-musl"
            if [[ ! -f "$out_dir/$dest_name" ]]; then
                cp "$bin" "$out_dir/$dest_name"
                ((copied++)) || true
            fi
        fi
    done

    if [[ $copied -gt 0 ]]; then
        echo "  [$id] OK  $copied binary(ies) staged"
        ((passed++)) || true
    else
        echo "  [$id] FAIL  built but no ELF binaries found in $bin_dir"
        echo "  [$id]   contents: $(ls "$bin_dir" 2>/dev/null | head -20 || echo '(empty)')"
        ((failed++)) || true
    fi

    rm -rf "$clone_dir"
}

echo "=== plasmidBin build-primal — $(date -Iseconds) ==="
echo "Target:  $TARGET"
echo "Staging: $STAGING/primals/$TARGET"
echo ""

mkdir -p "$BUILD_ROOT"

FILTER="${FILTER,,}"

if $BUILD_ALL; then
    for source_id in $(list_sources); do
        build_one "$source_id"
    done
else
    build_one "$FILTER"
fi

echo ""
echo "=== Build Summary ==="
echo "  Passed:  $passed"
echo "  Failed:  $failed"
echo "  Skipped: $skipped"
if [[ $failed_private -gt 0 ]]; then
    echo "  Private repo failures: $failed_private (not blocking — public bins still harvested)"
fi

if $DO_HARVEST && [[ $passed -gt 0 ]]; then
    echo ""
    echo "=== Harvesting ==="
    HARVEST_ARGS=(--source "$STAGING/primals/$TARGET" --arch "$ARCH")
    if [[ -n "$RELEASE_TAG" ]]; then
        HARVEST_ARGS+=(--release "$RELEASE_TAG")
    fi
    if ! $BUILD_ALL && [[ -n "$FILTER" ]]; then
        HARVEST_ARGS+=(--primal "$FILTER")
    fi
    "$SCRIPT_DIR/harvest.sh" "${HARVEST_ARGS[@]}"
fi

if [[ $passed -eq 0 ]]; then
    echo "ERROR: No primals built successfully"
    exit 1
fi
if [[ $failed -gt 0 ]]; then
    echo "WARNING: $failed build(s) failed but $passed succeeded — continuing"
fi
