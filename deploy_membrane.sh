#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# plasmidBin/deploy_membrane.sh — Provision and deploy membrane channels
#
# Deploys sovereign infrastructure to a VPS for NUCLEUS external surface.
# Three membrane channels (see wateringHole/MEMBRANE_CHANNEL_ARCHITECTURE.md):
#   Channel 1: Signal  (DNS — knot-dns, :53)           [future]
#   Channel 2: Relay   (NAT — songbird relay, :3478)    [active]
#   Channel 3: Surface (TLS — beardog-tls + nestgate)   [future]
#
# Modes:
#   provision  — Create a DigitalOcean droplet via doctl, then deploy
#   deploy     — SSH into existing VPS and deploy channel binaries
#   status     — Check health of deployed channels
#   teardown   — Destroy the droplet (requires confirmation)
#
# Usage:
#   ./deploy_membrane.sh provision --region nyc1
#   ./deploy_membrane.sh deploy root@<vps-ip>
#   ./deploy_membrane.sh status root@<vps-ip>
#   ./deploy_membrane.sh teardown --name membrane-relay
#   ./deploy_membrane.sh deploy root@<vps-ip> --dry-run
#
# Prerequisites:
#   - doctl CLI installed and authenticated (doctl auth init)
#   - SSH key registered with DigitalOcean (for provision mode)
#   - Songbird binary in plasmidBin/primals/x86_64-unknown-linux-musl/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MEMBRANE_DIR="$SCRIPT_DIR/membrane"
PRIMALS_DIR="$SCRIPT_DIR/primals"
REMOTE_MEMBRANE_DIR="/opt/membrane"

DROPLET_NAME="membrane-relay"
DROPLET_SIZE="s-1vcpu-512mb-10gb"
DROPLET_IMAGE="debian-12-x64"
DROPLET_REGION="nyc1"

DRY_RUN=false
MODE=""
REMOTE=""
SSH_KEY_FINGERPRINT=""

# ── Helpers ──────────────────────────────────────────────────────────

log()  { echo "[membrane] $*"; }
warn() { echo "[membrane] WARNING: $*" >&2; }
die()  { echo "[membrane] ERROR: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: deploy_membrane.sh <mode> [options]

Modes:
  provision              Create a DigitalOcean droplet and deploy channels
  deploy <user@host>     Deploy channel binaries to an existing VPS
  status <user@host>     Check health of deployed channels
  teardown               Destroy the membrane droplet

Options:
  --region REGION        DigitalOcean region (default: nyc1)
  --size SIZE            Droplet size slug (default: s-1vcpu-512mb-10gb)
  --name NAME            Droplet name (default: membrane-relay)
  --ssh-key FP           SSH key fingerprint for droplet access
  --dry-run              Show plan without executing
  --help                 Show this help

Deployment Models (from MEMBRANE_CHANNEL_ARCHITECTURE.md):
  Model A: Single VPS, all channels on one box (default)
  Model B: Multi-VPS, one channel per box (use multiple provision calls)
  Model C: Hybrid, Channel 3 on gate hardware + Channels 1+2 on VPS

Channels deployed:
  Channel 2 (Relay): songbird relay on :3478 — ACTIVE
  Channel 1 (Signal): knot-dns on :53        — FUTURE
  Channel 3 (Surface): beardog-tls on :443   — FUTURE
EOF
}

# ── Channel deployment functions ─────────────────────────────────────
# Each channel is a self-contained function. Add new channels here
# without modifying the deploy orchestration logic.
#
# Pull model: binaries are fetched from GitHub Releases on the VPS
# itself — the local machine never needs to hold or SCP binaries.
# This mirrors the bootstrap_gate.sh pattern.

GITHUB_REPO="ecoPrimals/plasmidBin"
GITHUB_RAW="https://raw.githubusercontent.com/$GITHUB_REPO/main"

remote_fetch_songbird() {
    local remote="$1"

    log "  Fetching songbird from GitHub Releases on VPS..."

    ssh "$remote" "bash -s" <<'FETCH'
set -euo pipefail
REPO="ecoPrimals/plasmidBin"
DEST="/opt/membrane/songbird"
ARCH="x86_64-unknown-linux-musl"
ASSET="songbird-${ARCH}"

TAGS=$(curl -sf --max-time 10 "https://api.github.com/repos/$REPO/releases?per_page=10" \
    | grep -oP '"tag_name"\s*:\s*"\K[^"]+')

if [[ -z "$TAGS" ]]; then
    echo "ERROR: Could not list releases" >&2
    exit 1
fi

for TAG in $TAGS; do
    URL="https://github.com/$REPO/releases/download/$TAG/$ASSET"
    if curl -sfL --max-time 120 -o "$DEST" "$URL" 2>/dev/null; then
        chmod 755 "$DEST"
        echo "  Release: $TAG"
        echo "  Asset:   $ASSET"
        echo "  Fetched: $("$DEST" --version 2>/dev/null || echo 'binary ready')"
        exit 0
    fi
done

echo "ERROR: songbird not found in last 10 releases" >&2
exit 1
FETCH
}

deploy_channel_2_relay() {
    local remote="$1"

    log "Channel 2 (Relay): deploying songbird relay to $remote"
    log "  Source: GitHub Releases ($GITHUB_REPO)"

    if $DRY_RUN; then
        log "[dry-run] Would fetch songbird from GitHub Releases on VPS"
        log "[dry-run] Would upload songbird-relay.service to VPS"
        log "[dry-run] Would generate credentials.env"
        log "[dry-run] Would enable and start songbird-relay.service"
        return 0
    fi

    ssh "$remote" "mkdir -p $REMOTE_MEMBRANE_DIR /etc/songbird"

    remote_fetch_songbird "$remote"

    log "  Uploading systemd unit..."
    scp -q "$MEMBRANE_DIR/songbird-relay.service" "$remote:/etc/systemd/system/songbird-relay.service"

    if ! ssh "$remote" "test -f $REMOTE_MEMBRANE_DIR/credentials.env"; then
        log "  Generating relay credentials on VPS..."
        local hex_key
        hex_key=$(ssh "$remote" "head -c 32 /dev/urandom | xxd -p -c 64")

        ssh "$remote" "cat > $REMOTE_MEMBRANE_DIR/credentials.env << CRED
SONGBIRD_TURN_KEY=$hex_key
CRED
chmod 600 $REMOTE_MEMBRANE_DIR/credentials.env"

        ssh "$remote" "echo 'nucleus-relay:$hex_key' > /etc/songbird/relay-credentials && chmod 600 /etc/songbird/relay-credentials"

        log ""
        log "  ┌─────────────────────────────────────────────────────┐"
        log "  │ TURN credentials generated. Save these for clients: │"
        log "  │   SONGBIRD_TURN_USERNAME=nucleus-relay              │"
        log "  │   SONGBIRD_TURN_KEY=$hex_key"
        log "  │                                                     │"
        log "  │ Credentials stored on VPS at:                       │"
        log "  │   $REMOTE_MEMBRANE_DIR/credentials.env              │"
        log "  │   /etc/songbird/relay-credentials                   │"
        log "  └─────────────────────────────────────────────────────┘"
    else
        log "  Credentials already exist, preserving."
    fi

    log "  Enabling and starting songbird-relay..."
    ssh "$remote" "systemctl daemon-reload && systemctl enable songbird-relay && systemctl restart songbird-relay"

    log "  Channel 2 (Relay) deployed."
}

deploy_firewall() {
    local remote="$1"

    log "Configuring firewall..."

    if $DRY_RUN; then
        log "[dry-run] Would configure UFW: allow 22,53,80,443,3478"
        return 0
    fi

    ssh "$remote" "bash -s" <<'FIREWALL'
if command -v ufw >/dev/null 2>&1; then
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp comment 'SSH management'
    ufw allow 53/tcp comment 'Channel 1: Signal (DNS)'
    ufw allow 53/udp comment 'Channel 1: Signal (DNS)'
    ufw allow 3478/tcp comment 'Channel 2: Relay (TURN)'
    ufw allow 3478/udp comment 'Channel 2: Relay (TURN)'
    ufw allow 80/tcp comment 'Channel 3: Surface (ACME)'
    ufw allow 443/tcp comment 'Channel 3: Surface (HTTPS)'
    ufw --force enable
    echo "UFW configured."
else
    echo "UFW not found — install with: apt install ufw"
fi
FIREWALL

    log "  Firewall configured."
}

harden_ssh() {
    local remote="$1"

    log "Hardening SSH..."

    if $DRY_RUN; then
        log "[dry-run] Would disable password auth, set PermitRootLogin to prohibit-password"
        return 0
    fi

    ssh "$remote" "bash -s" <<'HARDEN'
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
echo "SSH hardened."
HARDEN

    log "  SSH hardened (key-based only)."
}

status_channel_2_relay() {
    local remote="$1"

    log "Channel 2 (Relay) status:"
    ssh "$remote" "systemctl is-active songbird-relay 2>/dev/null && echo '  State: RUNNING' || echo '  State: STOPPED'"
    ssh "$remote" "systemctl show songbird-relay --property=ActiveEnterTimestamp 2>/dev/null | sed 's/^/  /'" || true
    ssh "$remote" "ss -tlnp 2>/dev/null | grep ':3478' | sed 's/^/  Listening: /' || echo '  Port 3478: not listening'"
}

# ── Mode: provision ──────────────────────────────────────────────────

do_provision() {
    command -v doctl >/dev/null 2>&1 || die "doctl not installed. Install: https://docs.digitalocean.com/reference/doctl/"

    if [[ -z "$SSH_KEY_FINGERPRINT" ]]; then
        log "Detecting SSH keys registered with DigitalOcean..."
        local keys
        keys=$(doctl compute ssh-key list --format FingerPrint,Name --no-header 2>/dev/null || true)
        if [[ -z "$keys" ]]; then
            die "No SSH keys registered with DigitalOcean. Add one at https://cloud.digitalocean.com/account/security"
        fi
        SSH_KEY_FINGERPRINT=$(echo "$keys" | head -1 | awk '{print $1}')
        log "  Using SSH key: $SSH_KEY_FINGERPRINT ($(echo "$keys" | head -1 | awk '{print $2}'))"
    fi

    log "Provisioning droplet: $DROPLET_NAME"
    log "  Region: $DROPLET_REGION"
    log "  Size:   $DROPLET_SIZE"
    log "  Image:  $DROPLET_IMAGE"

    if $DRY_RUN; then
        log "[dry-run] Would create droplet via doctl"
        log "[dry-run] Would wait for IP assignment"
        log "[dry-run] Would deploy channels"
        return 0
    fi

    local droplet_id
    droplet_id=$(doctl compute droplet create "$DROPLET_NAME" \
        --region "$DROPLET_REGION" \
        --size "$DROPLET_SIZE" \
        --image "$DROPLET_IMAGE" \
        --ssh-keys "$SSH_KEY_FINGERPRINT" \
        --tag-name "membrane" \
        --wait \
        --format ID \
        --no-header)

    log "  Droplet created: ID=$droplet_id"

    local ip
    ip=$(doctl compute droplet get "$droplet_id" --format PublicIPv4 --no-header)
    log "  Public IP: $ip"

    log "  Waiting for SSH to become available..."
    local attempts=0
    while ! ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "root@$ip" "echo ok" >/dev/null 2>&1; do
        attempts=$((attempts + 1))
        if [[ $attempts -ge 30 ]]; then
            die "SSH not available after 150s. Check droplet status: doctl compute droplet get $droplet_id"
        fi
        sleep 5
    done
    log "  SSH ready."

    REMOTE="root@$ip"
    do_deploy

    log ""
    log "┌─────────────────────────────────────────────────────────┐"
    log "│ Membrane VPS provisioned and deployed.                  │"
    log "│                                                         │"
    log "│   IP:       $ip"
    log "│   SSH:      ssh root@$ip"
    log "│   Droplet:  $DROPLET_NAME (ID: $droplet_id)"
    log "│                                                         │"
    log "│ Channel 2 (Relay): songbird on :3478                    │"
    log "│                                                         │"
    log "│ Client config:                                          │"
    log "│   export SONGBIRD_TURN_SERVER=$ip:3478"
    log "│   export SONGBIRD_TURN_USERNAME=nucleus-relay            │"
    log "│   export SONGBIRD_TURN_KEY=<see credentials above>      │"
    log "│                                                         │"
    log "│ Status: ./deploy_membrane.sh status root@$ip"
    log "└─────────────────────────────────────────────────────────┘"
}

# ── Mode: deploy ─────────────────────────────────────────────────────

do_deploy() {
    [[ -n "$REMOTE" ]] || die "No remote specified. Usage: deploy_membrane.sh deploy root@<ip>"

    log "Deploying membrane channels to $REMOTE"
    log "  Model A: all channels on single VPS"
    log ""

    ssh "$REMOTE" "apt-get update -qq && apt-get install -y -qq ufw xxd curl >/dev/null 2>&1" 2>/dev/null || true

    harden_ssh "$REMOTE"
    deploy_firewall "$REMOTE"
    deploy_channel_2_relay "$REMOTE"

    log ""
    log "Deployment complete. Run status to verify:"
    log "  ./deploy_membrane.sh status $REMOTE"
}

# ── Mode: status ─────────────────────────────────────────────────────

do_status() {
    [[ -n "$REMOTE" ]] || die "No remote specified. Usage: deploy_membrane.sh status root@<ip>"

    log "Membrane channel status for $REMOTE"
    log ""

    status_channel_2_relay "$REMOTE"

    log ""
    log "Channel 1 (Signal/DNS): not yet deployed"
    log "Channel 3 (Surface/TLS): not yet deployed"
}

# ── Mode: teardown ───────────────────────────────────────────────────

do_teardown() {
    command -v doctl >/dev/null 2>&1 || die "doctl not installed"

    local droplet_id
    droplet_id=$(doctl compute droplet list --tag-name membrane --format ID,Name --no-header | grep "$DROPLET_NAME" | awk '{print $1}')

    if [[ -z "$droplet_id" ]]; then
        die "No droplet named '$DROPLET_NAME' found with tag 'membrane'"
    fi

    log "Teardown: destroying droplet $DROPLET_NAME (ID: $droplet_id)"

    if $DRY_RUN; then
        log "[dry-run] Would destroy droplet $droplet_id"
        return 0
    fi

    read -rp "Type 'destroy' to confirm: " confirm
    if [[ "$confirm" != "destroy" ]]; then
        log "Aborted."
        return 1
    fi

    doctl compute droplet delete "$droplet_id" --force
    log "  Droplet destroyed."
}

# ── Argument parsing ─────────────────────────────────────────────────

[[ $# -ge 1 ]] || { usage; exit 1; }

MODE="$1"; shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --region)    DROPLET_REGION="$2"; shift 2 ;;
        --size)      DROPLET_SIZE="$2"; shift 2 ;;
        --name)      DROPLET_NAME="$2"; shift 2 ;;
        --ssh-key)   SSH_KEY_FINGERPRINT="$2"; shift 2 ;;
        --dry-run)   DRY_RUN=true; shift ;;
        --help)      usage; exit 0 ;;
        *)
            if [[ -z "${REMOTE:-}" && "$1" == *@* ]]; then
                REMOTE="$1"; shift
            else
                die "Unknown option: $1"
            fi
            ;;
    esac
done

case "$MODE" in
    provision) do_provision ;;
    deploy)    do_deploy ;;
    status)    do_status ;;
    teardown)  do_teardown ;;
    --help)    usage ;;
    *)         die "Unknown mode: $MODE. Use provision, deploy, status, or teardown." ;;
esac
