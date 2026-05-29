#!/usr/bin/env bash
# plasmidBin/onboard-gate-relay.sh — Onboard a gate to the VPS relay layer
#
# Pulls relay configuration from the VPS depot and writes it to the gate's
# environment file. Automates what is currently manual per-gate configuration
# for Songbird federation, TURN relay, RustDesk, and MitoBeacon identity.
#
# Pulls from VPS:
#   1. TURN credentials   (/etc/songbird/relay-credentials)
#   2. RustDesk public key (/opt/membrane/rustdesk/id_ed25519.pub)
#   3. MitoBeacon family seed (/etc/membrane/family/.beacon.seed)
#   4. Per-gate lineage seed  (/etc/membrane/family/nodes/<gate>.lineage.seed)
#
# Writes to gate:
#   /opt/membrane/relay.env — relay + federation + identity configuration
#
# Usage from VPS depot (local onboarding):
#   ./onboard-gate-relay.sh eastGate --vps-host localhost --gate-host 10.10.0.3
#
# Usage from any gate with VPS SSH access:
#   ./onboard-gate-relay.sh eastGate --vps-host 157.230.3.183
#
# Usage for local-only (write relay.env to this machine):
#   ./onboard-gate-relay.sh eastGate --vps-host 157.230.3.183 --local
#
# Prerequisites:
#   - SSH access to VPS (key-based auth)
#   - SSH access to gate (unless --local)

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

log()      { echo -e "${GREEN}[onboard]${NC} $1"; }
log_info() { echo -e "${CYAN}[onboard]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[onboard]${NC} $1"; }
log_err()  { echo -e "${RED}[onboard]${NC} $1"; }

GATE_NAME=""
VPS_HOST=""
VPS_USER="root"
VPS_PORT="22"
GATE_HOST=""
GATE_USER="root"
GATE_PORT="22"
LOCAL_MODE=false
DRY_RUN=false
RELAY_ENV_PATH="/opt/membrane/relay.env"
FEDERATION_PORT="7700"
TURN_PORT="3478"

usage() {
    echo "Usage: $0 <gate-name> --vps-host <host> [OPTIONS]"
    echo ""
    echo "Arguments:"
    echo "  <gate-name>              Gate identifier (e.g. eastGate, flockGate)"
    echo ""
    echo "Required:"
    echo "  --vps-host <host>        VPS depot hostname/IP"
    echo ""
    echo "Optional:"
    echo "  --gate-host <host>       Remote gate hostname/IP (for remote write)"
    echo "  --gate-user <user>       SSH user for gate (default: root)"
    echo "  --gate-port <port>       SSH port for gate (default: 22)"
    echo "  --vps-user <user>        SSH user for VPS (default: root)"
    echo "  --vps-port <port>        SSH port for VPS (default: 22)"
    echo "  --local                  Write relay.env to this machine"
    echo "  --relay-env <path>       Output path (default: /opt/membrane/relay.env)"
    echo "  --dry-run                Show what would be written"
    echo "  --help                   Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 eastGate --vps-host 157.230.3.183 --local"
    echo "  $0 flockGate --vps-host 157.230.3.183 --gate-host 192.168.1.50"
    echo "  $0 kinGate --vps-host 157.230.3.183 --gate-host kingate.local --gate-user ecoprimals"
}

if [[ $# -lt 1 ]]; then
    usage
    exit 1
fi

GATE_NAME="$1"; shift

while [[ $# -gt 0 ]]; do
    case $1 in
        --vps-host)   VPS_HOST="$2"; shift 2 ;;
        --vps-user)   VPS_USER="$2"; shift 2 ;;
        --vps-port)   VPS_PORT="$2"; shift 2 ;;
        --gate-host)  GATE_HOST="$2"; shift 2 ;;
        --gate-user)  GATE_USER="$2"; shift 2 ;;
        --gate-port)  GATE_PORT="$2"; shift 2 ;;
        --local)      LOCAL_MODE=true; shift ;;
        --relay-env)  RELAY_ENV_PATH="$2"; shift 2 ;;
        --dry-run)    DRY_RUN=true; shift ;;
        --help|-h)    usage; exit 0 ;;
        *) log_err "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ -z "$VPS_HOST" ]]; then
    log_err "--vps-host is required"
    exit 1
fi

if [[ "$LOCAL_MODE" == "false" && -z "$GATE_HOST" ]]; then
    log_err "Either --local or --gate-host is required"
    exit 1
fi

VPS_SSH="ssh -o StrictHostKeyChecking=accept-new -p $VPS_PORT $VPS_USER@$VPS_HOST"
GATE_SSH="ssh -o StrictHostKeyChecking=accept-new -p $GATE_PORT $GATE_USER@$GATE_HOST"

vps_read() {
    local path="$1"
    if [[ "$VPS_HOST" == "localhost" || "$VPS_HOST" == "127.0.0.1" ]]; then
        cat "$path" 2>/dev/null || echo ""
    else
        $VPS_SSH "cat $path 2>/dev/null" 2>/dev/null || echo ""
    fi
}

echo ""
log_info "════════════════════════════════════════════════════"
log_info "  Gate Relay Onboarding: $GATE_NAME"
log_info "════════════════════════════════════════════════════"
echo ""
log_info "VPS:       $VPS_USER@$VPS_HOST:$VPS_PORT"
if $LOCAL_MODE; then
    log_info "Target:    local ($RELAY_ENV_PATH)"
else
    log_info "Target:    $GATE_USER@$GATE_HOST:$GATE_PORT"
fi
log_info "Dry run:   $DRY_RUN"
echo ""

# ── Step 1: Pull TURN credentials ────────────────────────────────────────

log "Step 1: Pulling TURN relay credentials..."
TURN_USERNAME=$(vps_read "/etc/songbird/relay-credentials" | head -1)
TURN_KEY=$(vps_read "/etc/songbird/relay-credentials" | tail -1)

if [[ -n "$TURN_USERNAME" ]]; then
    log "  TURN username: $TURN_USERNAME"
else
    log_warn "  TURN credentials not found — TURN relay may not be configured"
    TURN_USERNAME="nucleus-relay"
    TURN_KEY=""
fi

# ── Step 2: Pull RustDesk public key ─────────────────────────────────────

log "Step 2: Pulling RustDesk public key..."
RUSTDESK_KEY=$(vps_read "/opt/membrane/rustdesk/id_ed25519.pub")

if [[ -n "$RUSTDESK_KEY" ]]; then
    log "  RustDesk key: ${RUSTDESK_KEY:0:20}..."
else
    log_warn "  RustDesk key not found — remote desktop relay unavailable"
fi

# ── Step 3: Pull MitoBeacon family seed ──────────────────────────────────

log "Step 3: Pulling MitoBeacon family seed..."
FAMILY_SEED=$(vps_read "/etc/membrane/family/.beacon.seed")
FAMILY_ID=$(vps_read "/etc/membrane/family/family_id")

if [[ -n "$FAMILY_SEED" ]]; then
    log "  Family ID: $FAMILY_ID"
    log "  Family seed: ${FAMILY_SEED:0:16}..."
else
    log_warn "  Family seed not found — MitoBeacon identity unavailable"
fi

# ── Step 4: Pull per-gate lineage seed ───────────────────────────────────

log "Step 4: Pulling per-gate lineage seed for $GATE_NAME..."
LINEAGE_SEED=$(vps_read "/etc/membrane/family/nodes/${GATE_NAME}.lineage.seed")

if [[ -n "$LINEAGE_SEED" ]]; then
    log "  Lineage seed: ${LINEAGE_SEED:0:16}..."
else
    log_warn "  Lineage seed not found for $GATE_NAME — will generate on first boot"
fi

# ── Step 5: Compose relay.env ────────────────────────────────────────────

log "Step 5: Composing relay.env..."

RELAY_ENV_CONTENT="# Relay configuration for $GATE_NAME
# Generated by onboard-gate-relay.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# VPS depot: $VPS_HOST

# Songbird Federation
SONGBIRD_PEERS=golgiBody@${VPS_HOST}:${FEDERATION_PORT}
SONGBIRD_NODE_ID=${GATE_NAME}

# Songbird TURN relay (NAT traversal)
SONGBIRD_TURN_SERVER=${VPS_HOST}:${TURN_PORT}
SONGBIRD_TURN_USERNAME=${TURN_USERNAME}
SONGBIRD_TURN_KEY=${TURN_KEY}

# MitoBeacon identity
FAMILY_ID=${FAMILY_ID}
FAMILY_SEED=${FAMILY_SEED}
NODE_ID=${GATE_NAME}
LINEAGE_SEED=${LINEAGE_SEED}

# RustDesk relay
RUSTDESK_ID_SERVER=${VPS_HOST}
RUSTDESK_RELAY_SERVER=${VPS_HOST}
RUSTDESK_KEY=${RUSTDESK_KEY}
"

if $DRY_RUN; then
    echo ""
    log_info "  [dry-run] Would write to: $RELAY_ENV_PATH"
    echo "  ────────────────────────────────────────"
    echo "$RELAY_ENV_CONTENT" | while IFS= read -r line; do echo "  $line"; done
    echo "  ────────────────────────────────────────"
else
    if $LOCAL_MODE; then
        mkdir -p "$(dirname "$RELAY_ENV_PATH")"
        echo "$RELAY_ENV_CONTENT" > "$RELAY_ENV_PATH"
        chmod 600 "$RELAY_ENV_PATH"
        log "  Written to: $RELAY_ENV_PATH"
    else
        $GATE_SSH "mkdir -p $(dirname "$RELAY_ENV_PATH")"
        echo "$RELAY_ENV_CONTENT" | $GATE_SSH "cat > $RELAY_ENV_PATH && chmod 600 $RELAY_ENV_PATH"
        log "  Written to: $GATE_HOST:$RELAY_ENV_PATH"
    fi
fi

# ── Step 6: Configure RustDesk (if installed) ────────────────────────────

log "Step 6: Checking RustDesk configuration..."

if $DRY_RUN; then
    log "  [dry-run] Would configure RustDesk to use VPS relay if installed"
elif $LOCAL_MODE; then
    RUSTDESK_CONF_DIR="$HOME/.config/rustdesk"
    if [[ -d "$RUSTDESK_CONF_DIR" ]] && [[ -n "$RUSTDESK_KEY" ]]; then
        log "  Configuring local RustDesk..."
        if [[ -f "$RUSTDESK_CONF_DIR/RustDesk.toml" ]]; then
            log_warn "  RustDesk.toml exists — manual config recommended"
        fi
    else
        log "  RustDesk not installed or no key — skipping"
    fi
else
    RUSTDESK_PRESENT=$($GATE_SSH "command -v rustdesk >/dev/null 2>&1 && echo yes || echo no" 2>/dev/null || echo "no")
    if [[ "$RUSTDESK_PRESENT" == "yes" && -n "$RUSTDESK_KEY" ]]; then
        log "  RustDesk found on $GATE_HOST — manual config recommended"
        log "  Set id-server=$VPS_HOST and relay-server=$VPS_HOST"
    else
        log "  RustDesk not installed on gate — skipping"
    fi
fi

# ── Summary ──────────────────────────────────────────────────────────────

echo ""
log_info "════════════════════════════════════════════════════"
log_info "  Onboarding Complete: $GATE_NAME"
log_info "════════════════════════════════════════════════════"
echo ""

ITEMS=0
FOUND=0
for val in "$TURN_USERNAME" "$RUSTDESK_KEY" "$FAMILY_SEED" "$LINEAGE_SEED"; do
    ITEMS=$((ITEMS + 1))
    [[ -n "$val" ]] && FOUND=$((FOUND + 1))
done

log_info "  Relay items: $FOUND / $ITEMS configured"
[[ -n "$TURN_USERNAME" ]] && log "  ✓ TURN relay"     || log_warn "  ✗ TURN relay"
[[ -n "$RUSTDESK_KEY" ]]  && log "  ✓ RustDesk relay" || log_warn "  ✗ RustDesk relay"
[[ -n "$FAMILY_SEED" ]]   && log "  ✓ Family seed"    || log_warn "  ✗ Family seed"
[[ -n "$LINEAGE_SEED" ]]  && log "  ✓ Lineage seed"   || log_warn "  ✗ Lineage seed"
echo ""

if ! $DRY_RUN; then
    log_info "  Next steps:"
    log_info "    1. Source relay.env in tower.env or systemd EnvironmentFile"
    log_info "    2. Restart Songbird to join federation mesh"
    log_info "    3. Verify: songbird peers list (should show golgiBody)"
fi

echo ""
