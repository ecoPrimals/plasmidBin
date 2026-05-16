#!/usr/bin/env bash
# plasmidBin/stage_usb.sh — Stage primal binaries for USB / offline deployment
#
# Exports primal binaries + metadata into a self-contained directory suitable
# for lithoSpore USB assembly (Tier 3) or offline gate bootstrapping.
#
# Usage:
#   ./stage_usb.sh --dest /mnt/usb/ecoprimals             # Stage all primals for host arch
#   ./stage_usb.sh --dest /tmp/usb --arch x86_64           # Explicit arch
#   ./stage_usb.sh --dest /tmp/usb --composition nucleus   # Only NUCLEUS (9 primals)
#   ./stage_usb.sh --dest /tmp/usb --verify                # Re-verify checksums after copy
#   ./stage_usb.sh --dest /tmp/usb --dry-run               # Show what would be staged
#
# Output layout (genomeBin canonical):
#   <dest>/
#   ├── manifest.toml
#   ├── checksums.toml
#   ├── ports.env
#   ├── primals/<triple>/
#   │   ├── beardog
#   │   ├── songbird
#   │   └── ... (all primals in composition)
#   └── VERSION
#
# Prerequisites:
#   - b3sum (optional, for --verify)
#   - ports.env must define primals_for_composition() if using --composition

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECKSUMS_FILE="$SCRIPT_DIR/checksums.toml"
MANIFEST_FILE="$SCRIPT_DIR/manifest.toml"
PORTS_FILE="$SCRIPT_DIR/ports.env"
PRIMALS_DIR="$SCRIPT_DIR/primals"

DEST=""
ARCH=""
COMPOSITION="full"
DRY_RUN=false
VERIFY=false

STAGED=0
SKIPPED=0
FAILED=0

usage() {
    echo "Usage: $0 --dest DIR [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --dest DIR           Destination directory (required)"
    echo "  --arch ARCH          Target architecture: x86_64 (default), aarch64, armv7"
    echo "  --composition NAME   Composition to stage (default: full)"
    echo "                       tower, node, nest, nucleus, meta, full,"
    echo "                       or niche-<spring>"
    echo "  --verify             Re-verify BLAKE3 checksums after copy"
    echo "  --dry-run            Show what would be staged, don't write"
    echo "  --help               Show this help"
    echo ""
    echo "Output: a self-contained directory with primals/<triple>/ layout,"
    echo "manifest.toml, checksums.toml, ports.env, and VERSION metadata."
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dest)          DEST="$2"; shift 2 ;;
        --arch)          ARCH="$2"; shift 2 ;;
        --composition)   COMPOSITION="$2"; shift 2 ;;
        --verify)        VERIFY=true; shift ;;
        --dry-run)       DRY_RUN=true; shift ;;
        --help)          usage; exit 0 ;;
        -*)              echo "Unknown option: $1"; usage; exit 1 ;;
        *)               echo "Unknown argument: $1"; usage; exit 1 ;;
    esac
done

if [[ -z "$DEST" ]]; then
    echo "ERROR: --dest is required"
    usage
    exit 1
fi

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

arch_to_full_triple() {
    case "$1" in
        x86_64)  echo "x86_64-unknown-linux-musl" ;;
        aarch64) echo "aarch64-unknown-linux-musl" ;;
        armv7)   echo "armv7-unknown-linux-musleabihf" ;;
        *)       echo "$1-unknown-linux-musl" ;;
    esac
}

if [[ -z "$ARCH" ]]; then
    ARCH=$(detect_arch)
fi

FULL_TRIPLE=$(arch_to_full_triple "$ARCH")

has_b3sum() { command -v b3sum >/dev/null 2>&1; }

# Parse a TOML value from a file (reused from fetch.sh / harvest.sh pattern)
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
    done < "$file"
    return 1
}

get_expected_checksum() {
    local primal="$1"
    local triple="$2"
    parse_toml_value "$CHECKSUMS_FILE" "primals.${primal}" "\"${triple}\"" 2>/dev/null || true
}

# Resolve the primal list for the requested composition.
# Source ports.env for primals_for_composition() if available.
resolve_primals() {
    local comp="$1"

    if [[ -f "$PORTS_FILE" ]]; then
        # shellcheck source=ports.env
        source "$PORTS_FILE"
        if type primals_for_composition &>/dev/null; then
            primals_for_composition "$comp" 2>/dev/null && return 0
        fi
    fi

    # Fallback: hardcoded full set (all 13 NUCLEUS primals)
    case "$comp" in
        full)
            echo "beardog songbird toadstool barracuda coralreef nestgate rhizocrypt loamspine sweetgrass biomeos squirrel petaltongue skunkbat"
            ;;
        nucleus)
            echo "beardog songbird toadstool barracuda coralreef nestgate rhizocrypt loamspine sweetgrass"
            ;;
        tower)
            echo "beardog songbird skunkbat"
            ;;
        node)
            echo "beardog songbird toadstool barracuda coralreef"
            ;;
        nest)
            echo "beardog songbird nestgate rhizocrypt loamspine sweetgrass"
            ;;
        meta)
            echo "biomeos squirrel petaltongue"
            ;;
        *)
            echo "ERROR: Unknown composition: $comp (and ports.env not available)" >&2
            return 1
            ;;
    esac
}

# Resolve the local path for a primal binary.
# Prefers canonical triple-first layout, falls back to legacy flat/aarch64.
resolve_binary() {
    local primal="$1"

    # Canonical: primals/<full-triple>/<primal>
    if [[ -f "$PRIMALS_DIR/$FULL_TRIPLE/$primal" ]]; then
        echo "$PRIMALS_DIR/$FULL_TRIPLE/$primal"
        return 0
    fi

    # Legacy: x86_64 flat at primals/<primal>, aarch64 at primals/aarch64/<primal>
    case "$ARCH" in
        x86_64)
            if [[ -f "$PRIMALS_DIR/$primal" ]]; then
                echo "$PRIMALS_DIR/$primal"
                return 0
            fi
            ;;
        aarch64)
            if [[ -f "$PRIMALS_DIR/aarch64/$primal" ]]; then
                echo "$PRIMALS_DIR/aarch64/$primal"
                return 0
            fi
            ;;
        armv7)
            if [[ -f "$PRIMALS_DIR/armv7/$primal" ]]; then
                echo "$PRIMALS_DIR/armv7/$primal"
                return 0
            fi
            ;;
    esac

    return 1
}

echo "plasmidBin stage_usb — $(date -Iseconds)"
echo "Arch:        $ARCH ($FULL_TRIPLE)"
echo "Composition: $COMPOSITION"
echo "Dest:        $DEST"
echo ""

PRIMALS=$(resolve_primals "$COMPOSITION") || exit 1
PRIMAL_COUNT=$(echo "$PRIMALS" | wc -w)
echo "Staging $PRIMAL_COUNT primals: $PRIMALS"
echo ""

if ! $DRY_RUN; then
    mkdir -p "$DEST/primals/$FULL_TRIPLE"
fi

TOTAL_SIZE=0

for primal in $PRIMALS; do
    src=$(resolve_binary "$primal" 2>/dev/null) || true

    if [[ -z "$src" || ! -f "$src" ]]; then
        echo "  [$primal] MISSING — binary not found for $FULL_TRIPLE"
        FAILED=$((FAILED + 1))
        continue
    fi

    size=$(stat --format='%s' "$src" 2>/dev/null || stat -f '%z' "$src" 2>/dev/null || echo 0)
    size_mb=$(awk "BEGIN { printf \"%.1f\", $size / 1048576 }")

    dest_path="$DEST/primals/$FULL_TRIPLE/$primal"

    if $DRY_RUN; then
        echo "  [$primal] STAGE  ${size_mb}M  $src -> $dest_path"
        STAGED=$((STAGED + 1))
        TOTAL_SIZE=$((TOTAL_SIZE + size))
        continue
    fi

    cp "$src" "$dest_path"
    chmod +x "$dest_path"

    # Pre-copy checksum verification
    expected=$(get_expected_checksum "$primal" "$FULL_TRIPLE")
    if [[ -n "$expected" ]] && has_b3sum; then
        actual=$(b3sum --no-names "$dest_path")
        if [[ "$actual" != "$expected" ]]; then
            echo "  [$primal] FAIL  checksum mismatch after copy (expected ${expected:0:16}..., got ${actual:0:16}...)"
            rm -f "$dest_path"
            FAILED=$((FAILED + 1))
            continue
        fi
        if $VERIFY; then
            echo "  [$primal] OK  ${size_mb}M  checksum verified"
        else
            echo "  [$primal] OK  ${size_mb}M"
        fi
    else
        echo "  [$primal] OK  ${size_mb}M  (no checksum entry or b3sum unavailable)"
    fi

    STAGED=$((STAGED + 1))
    TOTAL_SIZE=$((TOTAL_SIZE + size))
done

echo ""

# Copy metadata files
if ! $DRY_RUN; then
    for meta in manifest.toml checksums.toml ports.env; do
        if [[ -f "$SCRIPT_DIR/$meta" ]]; then
            cp "$SCRIPT_DIR/$meta" "$DEST/$meta"
            echo "  [metadata] $meta"
        fi
    done

    # Write VERSION file with staging provenance
    GIT_SHA=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    TOTAL_MB=$(awk "BEGIN { printf \"%.1f\", $TOTAL_SIZE / 1048576 }")
    cat > "$DEST/VERSION" <<EOF
# plasmidBin USB staging metadata
staged_at = "$(date -Iseconds)"
plasmidbin_commit = "$GIT_SHA"
arch = "$FULL_TRIPLE"
composition = "$COMPOSITION"
primal_count = $STAGED
total_size_mb = $TOTAL_MB
staged_by = "stage_usb.sh"
EOF
    echo "  [metadata] VERSION"
else
    echo "  [dry-run] Would copy: manifest.toml, checksums.toml, ports.env, VERSION"
fi

echo ""
TOTAL_MB=$(awk "BEGIN { printf \"%.1f\", $TOTAL_SIZE / 1048576 }")
echo "Summary:"
echo "  Staged:  $STAGED / $PRIMAL_COUNT"
echo "  Missing: $FAILED"
echo "  Skipped: $SKIPPED"
echo "  Total:   ${TOTAL_MB}M"

if [[ $FAILED -gt 0 ]]; then
    echo ""
    echo "WARNING: $FAILED primal(s) missing. USB artifact is incomplete."
    echo "Run ./fetch.sh --all first to ensure all binaries are present."
    exit 1
fi

echo ""
echo "USB staging complete. Destination: $DEST"
