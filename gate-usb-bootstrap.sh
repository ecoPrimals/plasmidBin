#!/usr/bin/env bash
# gate-usb-bootstrap.sh — Bootstrap a fresh Linux gate from USB
#
# Installs WireGuard, configures mesh, installs RustDesk pointing at the
# self-hosted relay, copies NUCLEUS primal binaries, and prints the info
# the operator needs to RustDesk in and hand off to a Cursor agent.
#
# Usage:
#   sudo ./gate-usb-bootstrap.sh                    # Interactive (prompts for gate name/IP)
#   sudo ./gate-usb-bootstrap.sh --gate southGate   # Read from gate-template.toml
#
# Prerequisites: fresh Linux install with apt or dnf available.
# Run as root (or with sudo).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENROLL_DIR="$SCRIPT_DIR/enroll"
PRIMALS_DIR="$SCRIPT_DIR/primals"
RUSTDESK_DIR="$ENROLL_DIR/rustdesk"
HUB_PEER="$ENROLL_DIR/hub-peer.conf"
TEMPLATE="$ENROLL_DIR/gate-template.toml"
DEPLOY_DIR="/opt/plasmidBin/primals"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${GREEN}[bootstrap]${NC} $*"; }
warn() { echo -e "${YELLOW}[warning]${NC} $*"; }
err()  { echo -e "${RED}[error]${NC} $*" >&2; }
banner() { echo -e "\n${CYAN}${BOLD}═══ $* ═══${NC}\n"; }

die() { err "$@"; exit 1; }

GATE_NAME=""
WG_IP=""
COMPOSITION="full"
FAMILY_ID="ecoPrimals"

# ── Parse arguments ──────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --gate)  GATE_NAME="$2"; shift 2 ;;
        --ip)    WG_IP="$2"; shift 2 ;;
        --help)
            echo "Usage: sudo $0 [--gate NAME] [--ip 10.13.37.X]"
            echo ""
            echo "Bootstraps a fresh Linux gate into the ecoPrimals mesh."
            echo "If --gate/--ip are omitted, reads from enroll/gate-template.toml"
            echo "or prompts interactively."
            exit 0
            ;;
        *) die "Unknown option: $1" ;;
    esac
done

# ── Require root ─────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    die "This script must be run as root (use sudo)"
fi

# ── Read from template if not passed as args ─────────────────────────
parse_toml_val() {
    local file="$1" key="$2"
    grep -E "^${key}[[:space:]]*=" "$file" 2>/dev/null \
        | sed 's/.*=[[:space:]]*"\(.*\)"/\1/' \
        | head -1
}

if [[ -z "$GATE_NAME" ]] && [[ -f "$TEMPLATE" ]]; then
    GATE_NAME=$(parse_toml_val "$TEMPLATE" "gate_name")
    [[ -z "$WG_IP" ]] && WG_IP=$(parse_toml_val "$TEMPLATE" "wg_ip")
    COMPOSITION=$(parse_toml_val "$TEMPLATE" "composition")
    FAMILY_ID=$(parse_toml_val "$TEMPLATE" "family_id")
fi

# ── Interactive prompts for missing values ───────────────────────────
if [[ -z "$GATE_NAME" ]]; then
    read -rp "Gate name (e.g. southGate): " GATE_NAME
    [[ -z "$GATE_NAME" ]] && die "Gate name is required"
fi

if [[ -z "$WG_IP" ]]; then
    read -rp "Mesh IP (e.g. 10.13.37.8): " WG_IP
    [[ -z "$WG_IP" ]] && die "Mesh IP is required"
fi

[[ -z "$COMPOSITION" ]] && COMPOSITION="full"
[[ -z "$FAMILY_ID" ]] && FAMILY_ID="ecoPrimals"

banner "ecoPrimals Gate Bootstrap"
log "Gate:        $GATE_NAME"
log "Mesh IP:     $WG_IP"
log "Composition: $COMPOSITION"
log "Family:      $FAMILY_ID"
echo ""

# ── Detect architecture ──────────────────────────────────────────────
detect_triple() {
    case "$(uname -m)" in
        x86_64)  echo "x86_64-unknown-linux-musl" ;;
        aarch64) echo "aarch64-unknown-linux-musl" ;;
        armv7l)  echo "armv7-unknown-linux-musleabihf" ;;
        *)       echo "$(uname -m)-unknown-linux-musl" ;;
    esac
}

TRIPLE=$(detect_triple)
log "Architecture: $TRIPLE"

# ── Detect package manager ───────────────────────────────────────────
install_pkg() {
    if command -v apt-get &>/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
    elif command -v dnf &>/dev/null; then
        dnf install -y "$@"
    elif command -v pacman &>/dev/null; then
        pacman -S --noconfirm "$@"
    else
        warn "No supported package manager found — install $* manually"
        return 1
    fi
}

# ═════════════════════════════════════════════════════════════════════
# STEP 1: WireGuard
# ═════════════════════════════════════════════════════════════════════
banner "Step 1/5: WireGuard"

if command -v wg &>/dev/null; then
    log "WireGuard already installed"
else
    log "Installing WireGuard..."
    install_pkg wireguard wireguard-tools || warn "WireGuard install failed — configure manually (see RELAY_MANUAL.md)"
fi

if command -v wg &>/dev/null; then
    WG_DIR="/etc/wireguard"
    mkdir -p "$WG_DIR"
    chmod 700 "$WG_DIR"

    if [[ -f "$WG_DIR/privatekey" ]]; then
        log "WireGuard keypair already exists"
        WG_PRIVKEY=$(cat "$WG_DIR/privatekey")
        WG_PUBKEY=$(cat "$WG_DIR/publickey")
    else
        log "Generating WireGuard keypair..."
        WG_PRIVKEY=$(wg genkey)
        WG_PUBKEY=$(echo "$WG_PRIVKEY" | wg pubkey)
        echo "$WG_PRIVKEY" > "$WG_DIR/privatekey"
        echo "$WG_PUBKEY" > "$WG_DIR/publickey"
        chmod 600 "$WG_DIR/privatekey"
    fi

    log "Writing wg0.conf..."
    cat > "$WG_DIR/wg0.conf" <<WGEOF
[Interface]
PrivateKey = $WG_PRIVKEY
Address = ${WG_IP}/24
DNS = 10.13.37.1

WGEOF

    if [[ -f "$HUB_PEER" ]]; then
        cat "$HUB_PEER" >> "$WG_DIR/wg0.conf"
        log "Hub peer block appended from enrollment bundle"
    else
        warn "No hub-peer.conf found — add golgiBody peer manually"
    fi

    chmod 600 "$WG_DIR/wg0.conf"

    log "Enabling wg-quick@wg0..."
    systemctl enable wg-quick@wg0 2>/dev/null || true
    systemctl start wg-quick@wg0 2>/dev/null || warn "Could not start WireGuard — start manually after adding peer on hub"

    echo ""
    log "WireGuard public key (add this to golgiBody):"
    echo -e "  ${BOLD}${WG_PUBKEY}${NC}"
    echo ""
    log "To add on golgiBody:"
    echo -e "  ${CYAN}ssh root@157.230.3.183 \"wg set wg0 peer ${WG_PUBKEY} allowed-ips ${WG_IP}/32\"${NC}"
else
    warn "WireGuard not available — skipping mesh configuration"
    WG_PUBKEY="N/A"
fi

# ═════════════════════════════════════════════════════════════════════
# STEP 2: Copy primal binaries
# ═════════════════════════════════════════════════════════════════════
banner "Step 2/5: Primal Binaries"

SRC_DIR="$PRIMALS_DIR/$TRIPLE"

if [[ -d "$SRC_DIR" ]]; then
    mkdir -p "$DEPLOY_DIR/$TRIPLE"
    COPIED=0
    for bin in "$SRC_DIR"/*; do
        [[ -f "$bin" ]] || continue
        name=$(basename "$bin")
        [[ "$name" == "checksums.toml" || "$name" == "signatures.toml" ]] && continue
        cp "$bin" "$DEPLOY_DIR/$TRIPLE/$name"
        chmod +x "$DEPLOY_DIR/$TRIPLE/$name"
        COPIED=$((COPIED + 1))
    done
    log "Copied $COPIED primal binaries to $DEPLOY_DIR/$TRIPLE/"

    for meta in manifest.toml checksums.toml ports.env; do
        if [[ -f "$SCRIPT_DIR/$meta" ]]; then
            cp "$SCRIPT_DIR/$meta" "/opt/plasmidBin/$meta"
        fi
    done
    log "Metadata files copied to /opt/plasmidBin/"
else
    warn "No binaries found for $TRIPLE at $SRC_DIR"
    warn "Binaries will need to be deployed via network after mesh is up"
fi

# ═════════════════════════════════════════════════════════════════════
# STEP 3: RustDesk
# ═════════════════════════════════════════════════════════════════════
banner "Step 3/5: RustDesk"

RUSTDESK_ID="N/A"

install_rustdesk() {
    if [[ -f "$RUSTDESK_DIR/rustdesk" ]]; then
        log "Installing RustDesk from USB bundle..."
        cp "$RUSTDESK_DIR/rustdesk" /usr/local/bin/rustdesk
        chmod +x /usr/local/bin/rustdesk
        return 0
    fi

    if command -v rustdesk &>/dev/null; then
        log "RustDesk already installed"
        return 0
    fi

    log "Downloading RustDesk..."
    local ver="1.3.9"
    local deb="/tmp/rustdesk-${ver}-x86_64.deb"
    if command -v curl &>/dev/null; then
        curl -fsSL "https://github.com/rustdesk/rustdesk/releases/download/${ver}/rustdesk-${ver}-x86_64.deb" -o "$deb" 2>/dev/null
    elif command -v wget &>/dev/null; then
        wget -q "https://github.com/rustdesk/rustdesk/releases/download/${ver}/rustdesk-${ver}-x86_64.deb" -O "$deb" 2>/dev/null
    else
        warn "Neither curl nor wget available — install RustDesk manually"
        return 1
    fi

    if [[ -f "$deb" ]]; then
        dpkg -i "$deb" 2>/dev/null || apt-get install -f -y 2>/dev/null || true
        rm -f "$deb"
    fi
}

configure_rustdesk() {
    local config_dir="/root/.config/rustdesk"
    mkdir -p "$config_dir"

    cat > "$config_dir/RustDesk2.toml" <<RDEOF
rendezvous_server = '157.230.3.183'
nat_type = 1
serial = 0

[options]
custom-rendezvous-server = '157.230.3.183'
relay-server = '157.230.3.183'
key = 'utlNOAWUDdV+Q+ifG3zHrQ5HU0FtQnOTHiAnu6prV7Q='
RDEOF

    log "RustDesk configured to use relay at 157.230.3.183 (remote.primals.eco)"
}

get_rustdesk_id() {
    if command -v rustdesk &>/dev/null; then
        local id
        id=$(rustdesk --get-id 2>/dev/null || true)
        if [[ -n "$id" ]]; then
            RUSTDESK_ID="$id"
            return 0
        fi
    fi

    if [[ -f /root/.config/rustdesk/RustDesk.toml ]]; then
        local id
        id=$(grep -oP 'id\s*=\s*'"'"'\K[^'"'"']+' /root/.config/rustdesk/RustDesk.toml 2>/dev/null || true)
        if [[ -n "$id" ]]; then
            RUSTDESK_ID="$id"
            return 0
        fi
    fi

    RUSTDESK_ID="(start RustDesk to generate ID)"
}

install_rustdesk || warn "RustDesk installation failed — see enroll/RELAY_MANUAL.md"
configure_rustdesk
get_rustdesk_id

# ═════════════════════════════════════════════════════════════════════
# STEP 4: MitoBeacon seed
# ═════════════════════════════════════════════════════════════════════
banner "Step 4/5: MitoBeacon Identity"

MEMBRANE_DIR="/etc/membrane"
FAMILY_DIR="$MEMBRANE_DIR/family"
mkdir -p "$FAMILY_DIR"

echo "$FAMILY_ID" > "$FAMILY_DIR/family_id"
echo "$GATE_NAME" > "$MEMBRANE_DIR/gate_name"

if [[ -f "$ENROLL_DIR/beacon.seed" ]]; then
    cp "$ENROLL_DIR/beacon.seed" "$FAMILY_DIR/.beacon.seed"
    chmod 600 "$FAMILY_DIR/.beacon.seed"
    log "Beacon seed installed from USB"
else
    log "No beacon seed on USB — will be pulled from hub after mesh is up"
fi

log "Gate identity: $GATE_NAME (family: $FAMILY_ID)"

# ═════════════════════════════════════════════════════════════════════
# STEP 5: Summary
# ═════════════════════════════════════════════════════════════════════
banner "Bootstrap Complete"

cat <<SUMMARY

  ${BOLD}Gate:${NC}        $GATE_NAME
  ${BOLD}Mesh IP:${NC}     $WG_IP
  ${BOLD}WG Pubkey:${NC}   $WG_PUBKEY
  ${BOLD}RustDesk ID:${NC} $RUSTDESK_ID
  ${BOLD}Arch:${NC}        $TRIPLE
  ${BOLD}Family:${NC}      $FAMILY_ID

  ${CYAN}${BOLD}Next steps:${NC}
  1. Add WireGuard peer on golgiBody:
     ${CYAN}ssh root@157.230.3.183 "wg set wg0 peer ${WG_PUBKEY} allowed-ips ${WG_IP}/32"${NC}

  2. Verify mesh connectivity:
     ${CYAN}ping -c 3 10.13.37.1${NC}

  3. Start RustDesk if not running:
     ${CYAN}rustdesk &${NC}

  4. RustDesk in from any machine, then let a Cursor agent run:
     ${CYAN}membrane gate.enroll $GATE_NAME${NC}
     ${CYAN}membrane gate.bootstrap $GATE_NAME --profile $COMPOSITION${NC}

  If automation fails, see: ${BOLD}enroll/RELAY_MANUAL.md${NC}

SUMMARY

# Copy RELAY_MANUAL.md to /opt for easy access
if [[ -f "$ENROLL_DIR/RELAY_MANUAL.md" ]]; then
    cp "$ENROLL_DIR/RELAY_MANUAL.md" /opt/plasmidBin/RELAY_MANUAL.md 2>/dev/null || true
fi
