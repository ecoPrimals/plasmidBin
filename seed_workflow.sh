#!/usr/bin/env bash
# plasmidBin/seed_workflow.sh — Dark Forest seed lifecycle management
#
# Generates, exports, and verifies the two-seed trust model:
#   1. Beacon seed (mitobeacon / mitochondrial DNA) — shared, enables discovery
#   2. Lineage seed (nuclear DNA) — per-device, controls authorization
#
# Uses beardog's crypto primitives (entropy, key generate/derive/export).
#
# Usage:
#   ./seed_workflow.sh init --family-name "eastgate-family"
#   ./seed_workflow.sh add-node --node-id pixel --family-dir ~/.config/biomeos/family/
#   ./seed_workflow.sh export --family-dir ~/.config/biomeos/family/ --format base64
#   ./seed_workflow.sh verify --family-dir ~/.config/biomeos/family/
#   ./seed_workflow.sh distribute --family-dir ~/.config/biomeos/family/ --node pixel
#
# Seeds directory layout:
#   ~/.config/biomeos/family/
#   ├── family.key          Master family key (PROTECT — never distribute)
#   ├── .beacon.seed        Beacon seed / mitobeacon (share with family)
#   ├── family_id            8-char family identifier
#   ├── nodes/
#   │   ├── devgate.lineage.seed   Lineage seed for dev gate
#   │   ├── pixel.lineage.seed     Lineage seed for Pixel
#   │   └── flockgate.lineage.seed Lineage seed for flockGate
#   └── exports/
#       ├── beacon.b64             Base64 beacon (for RustDesk paste)
#       └── pixel.lineage.b64     Base64 lineage for pixel

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BEARDOG="${BEARDOG_BIN:-$SCRIPT_DIR/primals/beardog}"

DEFAULT_FAMILY_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/biomeos/family"

COMMAND=""
FAMILY_NAME=""
FAMILY_DIR=""
NODE_ID=""
EXPORT_FORMAT="base64"
FORCE=false

usage() {
    echo "Usage: $0 <command> [OPTIONS]"
    echo ""
    echo "Commands:"
    echo "  init         Generate a new family root key, beacon seed, and family ID"
    echo "  add-node     Generate a lineage seed for a new device/node"
    echo "  export       Export seeds for distribution (base64 for RustDesk paste)"
    echo "  verify       Verify seed integrity and show family status"
    echo "  distribute   Generate a deploy-ready seed bundle for a specific node"
    echo ""
    echo "Options:"
    echo "  --family-name NAME   Human-readable family name (init only)"
    echo "  --family-dir DIR     Family seeds directory (default: $DEFAULT_FAMILY_DIR)"
    echo "  --node-id ID         Node identifier (add-node, distribute)"
    echo "  --format FMT         Export format: base64, hex, file (default: base64)"
    echo "  --force              Overwrite existing seeds"
    echo "  --help               Show this help"
}

if [[ $# -lt 1 ]]; then
    usage
    exit 1
fi

COMMAND="$1"
shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --family-name)  FAMILY_NAME="$2"; shift 2 ;;
        --family-dir)   FAMILY_DIR="$2"; shift 2 ;;
        --node-id)      NODE_ID="$2"; shift 2 ;;
        --format)       EXPORT_FORMAT="$2"; shift 2 ;;
        --force)        FORCE=true; shift ;;
        --help)         usage; exit 0 ;;
        -*)             echo "Unknown option: $1"; usage; exit 1 ;;
        *)              echo "Unknown argument: $1"; usage; exit 1 ;;
    esac
done

[[ -z "$FAMILY_DIR" ]] && FAMILY_DIR="$DEFAULT_FAMILY_DIR"

# ── Verify beardog binary ────────────────────────────────────────────────────

if [[ ! -x "$BEARDOG" ]]; then
    echo "ERROR: BearDog binary not found at $BEARDOG"
    echo "  Set BEARDOG_BIN or ensure primals/beardog exists"
    exit 1
fi

has_b3sum() { command -v b3sum >/dev/null 2>&1; }

generate_family_id() {
    if has_b3sum; then
        b3sum --no-names "$1" | head -c 8
    else
        sha256sum "$1" | head -c 8
    fi
}

# ── init: Create family root + beacon seed ───────────────────────────────────

cmd_init() {
    if [[ -z "$FAMILY_NAME" ]]; then
        FAMILY_NAME="family-$(date +%s | tail -c 6)"
        echo "  No --family-name provided, using: $FAMILY_NAME"
    fi

    if [[ -f "$FAMILY_DIR/family.key" ]] && ! $FORCE; then
        echo "ERROR: Family already initialized at $FAMILY_DIR"
        echo "  Use --force to reinitialize (DESTROYS existing seeds)"
        exit 1
    fi

    echo "=== Initializing Family: $FAMILY_NAME ==="
    echo "  Directory: $FAMILY_DIR"
    echo ""

    mkdir -p "$FAMILY_DIR/nodes" "$FAMILY_DIR/exports"
    chmod 700 "$FAMILY_DIR"

    # Step 1: Collect entropy and generate family root key
    echo "  [1/4] Collecting entropy..."
    ENTROPY_FILE=$(mktemp)
    "$BEARDOG" entropy collect --output "$ENTROPY_FILE" --identity "$FAMILY_NAME" 2>/dev/null || {
        # Fallback: use /dev/urandom if beardog entropy collection fails
        echo "    (beardog entropy unavailable, using /dev/urandom)"
        dd if=/dev/urandom bs=64 count=1 of="$ENTROPY_FILE" 2>/dev/null
    }

    echo "  [2/4] Generating family root key..."
    "$BEARDOG" key generate \
        --key-id "$FAMILY_NAME-root" \
        --seed "$ENTROPY_FILE" \
        --algorithm aes256-gcm 2>/dev/null || {
        echo "    (beardog key generate failed, using direct entropy)"
    }

    # The family master key is the entropy seed itself (or beardog key output)
    cp "$ENTROPY_FILE" "$FAMILY_DIR/family.key"
    chmod 600 "$FAMILY_DIR/family.key"
    rm -f "$ENTROPY_FILE"

    # Step 2: Derive beacon seed (mitobeacon) from family root
    echo "  [3/4] Deriving beacon seed (mitobeacon)..."
    BEACON_TMP=$(mktemp)
    "$BEARDOG" key derive \
        --master-key "$FAMILY_DIR/family.key" \
        --purpose "mitobeacon-discovery" \
        --output "$BEACON_TMP" 2>/dev/null || {
        # Fallback: HMAC-derive from family key using openssl
        echo "    (beardog derive unavailable, using openssl fallback)"
        openssl dgst -sha256 -hmac "mitobeacon-discovery" -binary "$FAMILY_DIR/family.key" > "$BEACON_TMP" 2>/dev/null || {
            # Last resort: hash the family key with a purpose salt
            if has_b3sum; then
                cat "$FAMILY_DIR/family.key" <(echo -n "mitobeacon-discovery") | b3sum --no-names | xxd -r -p > "$BEACON_TMP"
            else
                cat "$FAMILY_DIR/family.key" <(echo -n "mitobeacon-discovery") | sha256sum | cut -d' ' -f1 | xxd -r -p > "$BEACON_TMP"
            fi
        }
    }
    cp "$BEACON_TMP" "$FAMILY_DIR/.beacon.seed"
    chmod 600 "$FAMILY_DIR/.beacon.seed"
    rm -f "$BEACON_TMP"

    # Step 3: Generate family ID from beacon seed
    echo "  [4/4] Generating family ID..."
    FAMILY_ID=$(generate_family_id "$FAMILY_DIR/.beacon.seed")
    echo "$FAMILY_ID" > "$FAMILY_DIR/family_id"
    echo "$FAMILY_NAME" > "$FAMILY_DIR/family_name"

    echo ""
    echo "=== Family Initialized ==="
    echo "  Family name:  $FAMILY_NAME"
    echo "  Family ID:    $FAMILY_ID"
    echo "  Directory:    $FAMILY_DIR"
    echo ""
    echo "  Files:"
    echo "    family.key       Master key (NEVER distribute)"
    echo "    .beacon.seed     Mitobeacon (share with family members)"
    echo "    family_id        8-char identifier"
    echo ""
    echo "  Next: Add nodes with:"
    echo "    $0 add-node --node-id devgate"
    echo "    $0 add-node --node-id pixel"
    echo "    $0 add-node --node-id flockgate"
}

# ── add-node: Generate lineage seed for a device ─────────────────────────────

cmd_add_node() {
    if [[ -z "$NODE_ID" ]]; then
        echo "ERROR: --node-id is required"
        exit 1
    fi

    if [[ ! -f "$FAMILY_DIR/family.key" ]]; then
        echo "ERROR: Family not initialized. Run '$0 init' first."
        exit 1
    fi

    LINEAGE_FILE="$FAMILY_DIR/nodes/${NODE_ID}.lineage.seed"

    if [[ -f "$LINEAGE_FILE" ]] && ! $FORCE; then
        echo "ERROR: Lineage seed already exists for $NODE_ID"
        echo "  $LINEAGE_FILE"
        echo "  Use --force to regenerate (DESTROYS existing lineage)"
        exit 1
    fi

    FAMILY_ID=$(cat "$FAMILY_DIR/family_id")
    echo "=== Adding Node: $NODE_ID ==="
    echo "  Family: $FAMILY_ID"
    echo ""

    echo "  Deriving lineage seed (nuclear DNA) for $NODE_ID..."
    LINEAGE_TMP=$(mktemp)
    "$BEARDOG" key derive \
        --master-key "$FAMILY_DIR/family.key" \
        --purpose "lineage-auth-$NODE_ID" \
        --output "$LINEAGE_TMP" 2>/dev/null || {
        echo "    (beardog derive unavailable, using openssl fallback)"
        openssl dgst -sha256 -hmac "lineage-auth-$NODE_ID" -binary "$FAMILY_DIR/family.key" > "$LINEAGE_TMP" 2>/dev/null || {
            if has_b3sum; then
                cat "$FAMILY_DIR/family.key" <(echo -n "lineage-auth-$NODE_ID") | b3sum --no-names | xxd -r -p > "$LINEAGE_TMP"
            else
                cat "$FAMILY_DIR/family.key" <(echo -n "lineage-auth-$NODE_ID") | sha256sum | cut -d' ' -f1 | xxd -r -p > "$LINEAGE_TMP"
            fi
        }
    }
    cp "$LINEAGE_TMP" "$LINEAGE_FILE"
    chmod 600 "$LINEAGE_FILE"
    rm -f "$LINEAGE_TMP"

    echo ""
    echo "=== Node Added ==="
    echo "  Node:          $NODE_ID"
    echo "  Lineage seed:  $LINEAGE_FILE"
    echo "  Family ID:     $FAMILY_ID"
    echo ""
    echo "  Deploy this node with:"
    echo "    $0 distribute --node-id $NODE_ID"
}

# ── export: Export seeds for distribution ─────────────────────────────────────

cmd_export() {
    if [[ ! -f "$FAMILY_DIR/.beacon.seed" ]]; then
        echo "ERROR: No beacon seed found. Run '$0 init' first."
        exit 1
    fi

    FAMILY_ID=$(cat "$FAMILY_DIR/family_id" 2>/dev/null || echo "unknown")
    echo "=== Exporting Seeds ==="
    echo "  Family ID: $FAMILY_ID"
    echo "  Format:    $EXPORT_FORMAT"
    echo ""

    case "$EXPORT_FORMAT" in
        base64)
            BEACON_B64=$(base64 -w0 "$FAMILY_DIR/.beacon.seed")
            echo "  Beacon seed (mitobeacon) — paste via RustDesk:"
            echo "    $BEACON_B64"
            echo "$BEACON_B64" > "$FAMILY_DIR/exports/beacon.b64"
            echo ""
            echo "  Use with deploy scripts:"
            echo "    ./deploy_gate.sh user@host --beacon-seed $FAMILY_DIR/.beacon.seed --dark-forest"
            echo "    ./bootstrap_gate.sh --family-id $FAMILY_ID --beacon-seed $BEACON_B64 --dark-forest"
            echo ""

            for lineage_file in "$FAMILY_DIR/nodes/"*.lineage.seed; do
                [[ -f "$lineage_file" ]] || continue
                node=$(basename "$lineage_file" .lineage.seed)
                LINEAGE_B64=$(base64 -w0 "$lineage_file")
                echo "  Lineage seed for $node:"
                echo "    $LINEAGE_B64"
                echo "$LINEAGE_B64" > "$FAMILY_DIR/exports/${node}.lineage.b64"
            done
            ;;
        hex)
            echo "  Beacon seed:"
            xxd -p "$FAMILY_DIR/.beacon.seed" | tr -d '\n'
            echo ""
            for lineage_file in "$FAMILY_DIR/nodes/"*.lineage.seed; do
                [[ -f "$lineage_file" ]] || continue
                node=$(basename "$lineage_file" .lineage.seed)
                echo "  Lineage ($node):"
                xxd -p "$lineage_file" | tr -d '\n'
                echo ""
            done
            ;;
        file)
            echo "  Files for deployment:"
            echo "    Beacon:  $FAMILY_DIR/.beacon.seed"
            for lineage_file in "$FAMILY_DIR/nodes/"*.lineage.seed; do
                [[ -f "$lineage_file" ]] || continue
                node=$(basename "$lineage_file" .lineage.seed)
                echo "    Lineage ($node): $lineage_file"
            done
            ;;
    esac
}

# ── verify: Check seed integrity and show family status ───────────────────────

cmd_verify() {
    if [[ ! -d "$FAMILY_DIR" ]]; then
        echo "ERROR: Family directory not found: $FAMILY_DIR"
        exit 1
    fi

    echo "=== Seed Verification ==="
    echo "  Directory: $FAMILY_DIR"
    echo ""

    ALL_OK=true

    # Family key
    if [[ -f "$FAMILY_DIR/family.key" ]]; then
        size=$(wc -c < "$FAMILY_DIR/family.key")
        perms=$(stat -c '%a' "$FAMILY_DIR/family.key" 2>/dev/null || stat -f '%Lp' "$FAMILY_DIR/family.key" 2>/dev/null)
        echo "  family.key:    OK (${size}B, mode $perms)"
        if [[ "$perms" != "600" ]]; then
            echo "    WARNING: Permissions should be 600, not $perms"
        fi
    else
        echo "  family.key:    MISSING"
        ALL_OK=false
    fi

    # Beacon seed
    if [[ -f "$FAMILY_DIR/.beacon.seed" ]]; then
        size=$(wc -c < "$FAMILY_DIR/.beacon.seed")
        if has_b3sum; then
            hash=$(b3sum --no-names "$FAMILY_DIR/.beacon.seed" | head -c 16)
        else
            hash=$(sha256sum "$FAMILY_DIR/.beacon.seed" | head -c 16)
        fi
        echo "  .beacon.seed:  OK (${size}B, hash=${hash}...)"
    else
        echo "  .beacon.seed:  MISSING"
        ALL_OK=false
    fi

    # Family ID
    if [[ -f "$FAMILY_DIR/family_id" ]]; then
        FAMILY_ID=$(cat "$FAMILY_DIR/family_id")
        echo "  family_id:     $FAMILY_ID"
    else
        echo "  family_id:     MISSING"
        ALL_OK=false
    fi

    # Family name
    if [[ -f "$FAMILY_DIR/family_name" ]]; then
        FAMILY_NAME=$(cat "$FAMILY_DIR/family_name")
        echo "  family_name:   $FAMILY_NAME"
    fi

    # Node lineage seeds
    echo ""
    echo "  Nodes:"
    NODE_COUNT=0
    for lineage_file in "$FAMILY_DIR/nodes/"*.lineage.seed; do
        [[ -f "$lineage_file" ]] || continue
        node=$(basename "$lineage_file" .lineage.seed)
        size=$(wc -c < "$lineage_file")
        if has_b3sum; then
            hash=$(b3sum --no-names "$lineage_file" | head -c 16)
        else
            hash=$(sha256sum "$lineage_file" | head -c 16)
        fi
        echo "    $node: OK (${size}B, hash=${hash}...)"
        NODE_COUNT=$((NODE_COUNT + 1))
    done

    if [[ $NODE_COUNT -eq 0 ]]; then
        echo "    (no nodes registered — use '$0 add-node --node-id <name>')"
    fi

    echo ""
    if $ALL_OK; then
        echo "  Status: HEALTHY ($NODE_COUNT nodes)"
    else
        echo "  Status: INCOMPLETE (missing seeds)"
        exit 1
    fi
}

# ── distribute: Create deploy-ready bundle for a node ─────────────────────────

cmd_distribute() {
    if [[ -z "$NODE_ID" ]]; then
        echo "ERROR: --node-id is required"
        exit 1
    fi

    if [[ ! -f "$FAMILY_DIR/.beacon.seed" ]]; then
        echo "ERROR: Beacon seed missing. Run '$0 init' first."
        exit 1
    fi

    LINEAGE_FILE="$FAMILY_DIR/nodes/${NODE_ID}.lineage.seed"
    if [[ ! -f "$LINEAGE_FILE" ]]; then
        echo "ERROR: No lineage seed for $NODE_ID. Run '$0 add-node --node-id $NODE_ID' first."
        exit 1
    fi

    FAMILY_ID=$(cat "$FAMILY_DIR/family_id" 2>/dev/null || echo "unknown")

    echo "=== Distribution Bundle for $NODE_ID ==="
    echo "  Family ID: $FAMILY_ID"
    echo ""

    BEACON_B64=$(base64 -w0 "$FAMILY_DIR/.beacon.seed")
    LINEAGE_B64=$(base64 -w0 "$LINEAGE_FILE")

    echo "  For SSH deploy (deploy_gate.sh):"
    echo "    ./deploy_gate.sh user@$NODE_ID \\"
    echo "      --family-id $FAMILY_ID \\"
    echo "      --family-seed $FAMILY_DIR/.beacon.seed \\"
    echo "      --beacon-seed $FAMILY_DIR/.beacon.seed \\"
    echo "      --dark-forest"
    echo ""

    echo "  For Pixel deploy (deploy_pixel.sh):"
    echo "    ./deploy_pixel.sh \\"
    echo "      --family-id $FAMILY_ID \\"
    echo "      --beacon-seed $FAMILY_DIR/.beacon.seed \\"
    echo "      --dark-forest"
    echo ""

    echo "  For bootstrap (paste via RustDesk):"
    echo "    curl -sL https://raw.githubusercontent.com/ecoPrimals/plasmidBin/main/bootstrap_gate.sh | \\"
    echo "      bash -s -- --family-id $FAMILY_ID --beacon-seed $BEACON_B64 --dark-forest"
    echo ""

    echo "  For start_primal.sh (local use):"
    echo "    export FAMILY_ID=$FAMILY_ID"
    echo "    export NODE_ID=$NODE_ID"
    echo "    ./start_primal.sh beardog --tcp-port 9100 --family-id $FAMILY_ID --dark-forest"
    echo "    ./start_primal.sh songbird --tcp-port 9200 --dark-forest --beardog-socket /tmp/biomeos/beardog-$FAMILY_ID.sock"
    echo ""

    # Save exports
    echo "$BEACON_B64" > "$FAMILY_DIR/exports/beacon.b64"
    echo "$LINEAGE_B64" > "$FAMILY_DIR/exports/${NODE_ID}.lineage.b64"

    echo "  Exports saved to:"
    echo "    $FAMILY_DIR/exports/beacon.b64"
    echo "    $FAMILY_DIR/exports/${NODE_ID}.lineage.b64"
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

case "$COMMAND" in
    init)        cmd_init ;;
    add-node)    cmd_add_node ;;
    export)      cmd_export ;;
    verify)      cmd_verify ;;
    distribute)  cmd_distribute ;;
    --help)      usage ;;
    *)
        echo "ERROR: Unknown command: $COMMAND"
        usage
        exit 1
        ;;
esac
