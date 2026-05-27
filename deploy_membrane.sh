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
# Compositions:
#   relay      — Channel 2 only: Songbird TURN relay (default)
#   rustdesk   — Songbird relay + RustDesk (hbbs+hbbr) for remote desktop
#   tower      — Full Tower atomic + RustDesk: BearDog + Songbird + SkunkBat + hbbs/hbbr
#                Adds BTSP identity, secrets delegation, defense audit, and remote desktop.
#   nest       — Tower + Nest Atomic: NestGate + rhizoCrypt + loamSpine + sweetGrass
#   nucleus    — Full NUCLEUS (13 primals): Tower + Node + Nest + Meta
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
#   ./deploy_membrane.sh deploy root@<vps-ip> --composition tower
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
VALIDATE_AFTER=false
MODE=""
REMOTE=""
SSH_KEY_FINGERPRINT=""
COMPOSITION="relay"

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
  keys <action> <u@h>    Manage SSH keys for multi-gate access
  teardown               Destroy the membrane droplet

Keys actions:
  keys add <u@h>  --name "gate-name" --pubkey "ssh-ed25519 AAAA..."
  keys list <u@h>
  keys revoke <u@h> --name "gate-name"

Options:
  --region REGION        DigitalOcean region (default: nyc1)
  --size SIZE            Droplet size slug (default: s-1vcpu-512mb-10gb)
  --name NAME            Droplet / gate name (context-dependent)
  --pubkey KEY           Public key string (for keys add)
  --ssh-key FP           SSH key fingerprint for droplet access
  --composition COMP     Deployment composition: relay, tower, nest, nucleus, or rustdesk
  --validate             Run post-deploy composition verification
  --dry-run              Show plan without executing
  --help                 Show this help

Compositions:
  relay     Channel 2 only: Songbird TURN relay
  rustdesk  Songbird relay + RustDesk (hbbs+hbbr) remote desktop
  tower     Full Tower + RustDesk: BearDog + Songbird + SkunkBat + hbbs/hbbr
  nest      Tower + Nest Atomic: adds NestGate + rhizoCrypt + loamSpine + sweetGrass
  nucleus   Full NUCLEUS: Tower + Node + Nest + Meta (all 13 primals)

Deployment Models (from MEMBRANE_CHANNEL_ARCHITECTURE.md):
  Model A: Single VPS, all channels on one box (default)
  Model B: Multi-VPS, one channel per box (use multiple provision calls)
  Model C: Hybrid, Channel 3 on gate hardware + Channels 1+2 on VPS

Channels deployed:
  Channel 2  (Relay):    songbird relay on :3478      — ACTIVE
  Channel 2b (RustDesk): hbbs :21116 + hbbr :21117    — ACTIVE (rustdesk/tower)
  Channel 1  (Signal):   knot-dns on :53              — FUTURE
  Channel 3  (Surface):  beardog-tls on :443          — FUTURE
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

    log "Configuring firewall (composition: $COMPOSITION)..."

    if $DRY_RUN; then
        log "[dry-run] Would configure UFW: allow 22 + composition-specific ports"
        return 0
    fi

    local rustdesk_rules=""
    if [[ "$COMPOSITION" == "rustdesk" || "$COMPOSITION" == "tower" ]]; then
        rustdesk_rules="
    ufw allow 21115/tcp comment 'RustDesk: NAT type test'
    ufw allow 21116/tcp comment 'RustDesk: ID registration'
    ufw allow 21116/udp comment 'RustDesk: hole punching'
    ufw allow 21117/tcp comment 'RustDesk: relay'"
    fi

    ssh "$remote" "bash -s" <<FIREWALL
if command -v ufw >/dev/null 2>&1; then
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp comment 'SSH management'
    ufw allow 3478/tcp comment 'Channel 2: Relay (TURN)'
    ufw allow 3478/udp comment 'Channel 2: Relay (TURN)'
    ${rustdesk_rules}
    ufw --force enable
    echo "UFW configured (composition: $COMPOSITION)."
else
    echo "UFW not found — install with: apt install ufw"
fi
FIREWALL

    log "  Firewall configured (composition: $COMPOSITION)."
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

# ── Tower composition functions ──────────────────────────────────────
# When --composition tower is used, the membrane gets the full Tower
# atomic: BearDog (crypto/BTSP), Songbird (relay/discovery), SkunkBat
# (defense/audit). This enables BTSP-based credential delegation and
# makes the membrane a proper gate with its own identity.

remote_fetch_primal() {
    local remote="$1"
    local primal="$2"

    log "  Fetching $primal from GitHub Releases on VPS..."

    ssh "$remote" "bash -s" <<FETCH
set -euo pipefail
REPO="ecoPrimals/plasmidBin"
DEST="/opt/membrane/$primal"
ARCH="x86_64-unknown-linux-musl"
ASSET="${primal}-\${ARCH}"

TAGS=\$(curl -sf --max-time 10 "https://api.github.com/repos/\$REPO/releases?per_page=10" \\
    | grep -oP '"tag_name"\s*:\s*"\K[^"]+')

if [[ -z "\$TAGS" ]]; then
    echo "ERROR: Could not list releases" >&2
    exit 1
fi

for TAG in \$TAGS; do
    URL="https://github.com/\$REPO/releases/download/\$TAG/\$ASSET"
    if curl -sfL --max-time 120 -o "\$DEST" "\$URL" 2>/dev/null; then
        chmod 755 "\$DEST"
        echo "  Release: \$TAG"
        echo "  Asset:   \$ASSET"
        echo "  Fetched: \$("\$DEST" --version 2>/dev/null || echo 'binary ready')"
        exit 0
    fi
done

echo "ERROR: $primal not found in last 10 releases" >&2
exit 1
FETCH
}

deploy_tower_composition() {
    local remote="$1"

    log "Tower composition: deploying BearDog + Songbird + SkunkBat"
    log "  Source: GitHub Releases ($GITHUB_REPO)"
    log ""

    if $DRY_RUN; then
        log "[dry-run] Would fetch beardog, songbird, skunkbat from GitHub Releases"
        log "[dry-run] Would upload Tower systemd units"
        log "[dry-run] Would create tower.env with FAMILY_ID"
        log "[dry-run] Would enable beardog-membrane, songbird-relay, skunkbat-membrane"
        return 0
    fi

    ssh "$remote" "mkdir -p $REMOTE_MEMBRANE_DIR /etc/membrane /etc/songbird /run/membrane"

    for primal in beardog songbird skunkbat; do
        if ssh "$remote" "test -x $REMOTE_MEMBRANE_DIR/$primal" 2>/dev/null; then
            log "  $primal already present, skipping fetch"
        else
            remote_fetch_primal "$remote" "$primal"
        fi
    done

    for meta in checksums.toml provenance.toml manifest.toml; do
        if [[ -f "$SCRIPT_DIR/$meta" ]]; then
            log "  Pushing $meta to VPS..."
            scp -q "$SCRIPT_DIR/$meta" "$remote:$REMOTE_MEMBRANE_DIR/$meta"
        fi
    done

    log "  Uploading systemd units..."
    scp -q "$MEMBRANE_DIR/beardog-membrane.service" "$remote:/etc/systemd/system/"
    scp -q "$MEMBRANE_DIR/songbird-relay.service"   "$remote:/etc/systemd/system/"
    scp -q "$MEMBRANE_DIR/skunkbat-membrane.service" "$remote:/etc/systemd/system/"

    if ! ssh "$remote" "test -f $REMOTE_MEMBRANE_DIR/tower.env"; then
        log "  Generating Tower environment..."
        ssh "$remote" "bash -s" <<'TENV_GEN'
FAMILY_ID=$(head -c 32 /dev/urandom | xxd -p -c 64)
cat > /opt/membrane/tower.env <<TENV
# Tower composition environment — cellMembrane fieldMouse
# Generated: $(date -Iseconds)
MEMBRANE_ROLE=tower
MEMBRANE_GATE_ID=membrane-$(hostname)
BEARDOG_FAMILY_SEED=${FAMILY_ID}
TENV
chmod 600 /opt/membrane/tower.env
echo "  FAMILY_ID generated (first 8 chars): ${FAMILY_ID:0:8}..."
TENV_GEN
    else
        log "  tower.env already exists, preserving."
    fi

    if ! ssh "$remote" "test -f $REMOTE_MEMBRANE_DIR/credentials.env"; then
        log "  Generating relay credentials on VPS..."
        local hex_key
        hex_key=$(ssh "$remote" "head -c 32 /dev/urandom | xxd -p -c 64")

        ssh "$remote" "cat > $REMOTE_MEMBRANE_DIR/credentials.env << CRED
SONGBIRD_TURN_KEY=$hex_key
CRED
chmod 600 $REMOTE_MEMBRANE_DIR/credentials.env"

        ssh "$remote" "echo 'nucleus-relay:$hex_key' > /etc/songbird/relay-credentials && chmod 600 /etc/songbird/relay-credentials"

        log "  TURN credentials generated."
    else
        log "  Credentials already exist, preserving."
    fi

    log "  Enabling Tower services..."
    ssh "$remote" "systemctl daemon-reload"
    ssh "$remote" "systemctl enable beardog-membrane songbird-relay skunkbat-membrane"
    ssh "$remote" "systemctl restart beardog-membrane songbird-relay skunkbat-membrane" 2>/dev/null || true

    log ""
    log "  Tower composition deployed."
    log "    BearDog:  /run/membrane/beardog.sock  (BTSP + crypto)"
    log "    Songbird: :3478                       (relay + discovery)"
    log "    SkunkBat: /run/membrane/skunkbat.sock (defense + audit)"
}

status_tower_composition() {
    local remote="$1"

    log "Tower composition status:"
    for svc in beardog-membrane songbird-relay skunkbat-membrane; do
        local state
        state=$(ssh "$remote" "systemctl is-active $svc 2>/dev/null || echo 'not-found'")
        local uptime
        uptime=$(ssh "$remote" "systemctl show $svc --property=ActiveEnterTimestamp 2>/dev/null | cut -d= -f2" || echo "unknown")
        log "  $svc: $state (since: $uptime)"
    done

    ssh "$remote" "ls -la /run/membrane/*.sock 2>/dev/null | sed 's/^/  Socket: /' || echo '  No sockets found'"
    ssh "$remote" "ss -tlnp 2>/dev/null | grep ':3478' | sed 's/^/  Listening: /' || echo '  Port 3478: not listening'"
}

# ── Nest Atomic expansion ────────────────────────────────────────────
# Adds NestGate + provenance trio (rhizoCrypt, loamSpine, sweetGrass)
# to an existing Tower deployment. Requires Tower already deployed.
# Memory budget: trio primals ~5-15MB RSS each, fits 2GB VPS alongside
# Tower + RustDesk + Caddy + petalTongue.
#
# Wave 29 (CM-1): cellMembrane Nest Atomic expansion

NEST_PRIMALS="nestgate rhizocrypt loamspine sweetgrass"

deploy_nest_composition() {
    local remote="$1"

    log "Nest expansion: adding NestGate + provenance trio to Tower"
    log "  Primals: $NEST_PRIMALS"
    log "  Source: GitHub Releases ($GITHUB_REPO)"
    log ""

    local has_tower
    has_tower=$(ssh "$remote" "test -x $REMOTE_MEMBRANE_DIR/beardog && echo yes || echo no")
    if [[ "$has_tower" != "yes" ]]; then
        die "Nest composition requires Tower already deployed. Run: deploy_membrane.sh deploy $remote --composition tower"
    fi

    if $DRY_RUN; then
        log "[dry-run] Would fetch nestgate, rhizocrypt, loamspine, sweetgrass from GitHub Releases"
        log "[dry-run] Would generate systemd units for Nest primals"
        log "[dry-run] Would open ports 9500 (NestGate), 9601 (rhizoCrypt), 9700 (loamSpine), 9850 (sweetGrass)"
        log "[dry-run] Would enable and start Nest services"
        return 0
    fi

    ssh "$remote" "mkdir -p $REMOTE_MEMBRANE_DIR /run/membrane"

    for primal in $NEST_PRIMALS; do
        if ssh "$remote" "test -x $REMOTE_MEMBRANE_DIR/$primal" 2>/dev/null; then
            log "  $primal already present, skipping fetch"
        else
            remote_fetch_primal "$remote" "$primal"
        fi
    done

    for meta in checksums.toml provenance.toml manifest.toml; do
        if [[ -f "$SCRIPT_DIR/$meta" ]]; then
            log "  Pushing $meta to VPS..."
            scp -q "$SCRIPT_DIR/$meta" "$remote:$REMOTE_MEMBRANE_DIR/$meta"
        fi
    done

    log "  Generating Nest systemd units..."
    local family_seed
    family_seed=$(ssh "$remote" "grep BEARDOG_FAMILY_SEED $REMOTE_MEMBRANE_DIR/tower.env 2>/dev/null | cut -d= -f2" || echo "")
    if [[ -z "$family_seed" ]]; then
        warn "Could not read FAMILY_SEED from tower.env — Nest primals will use default socket paths"
    fi

    ssh "$remote" "bash -s" <<NEST_UNITS
set -euo pipefail
FAMILY="\${1:-${family_seed:0:8}}"
MEMBRANE_DIR="$REMOTE_MEMBRANE_DIR"

cat > /etc/systemd/system/nestgate-membrane.service <<SVC
[Unit]
Description=NestGate — content-addressed storage (membrane)
After=network.target beardog-membrane.service
Wants=beardog-membrane.service

[Service]
Type=simple
ExecStart=\$MEMBRANE_DIR/nestgate service start --port 9500 --bind 0.0.0.0
Restart=on-failure
RestartSec=5
EnvironmentFile=-\$MEMBRANE_DIR/tower.env

[Install]
WantedBy=multi-user.target
SVC

cat > /etc/systemd/system/rhizocrypt-membrane.service <<SVC
[Unit]
Description=rhizoCrypt — ephemeral DAG sessions (membrane)
After=network.target

[Service]
Type=simple
ExecStart=\$MEMBRANE_DIR/rhizocrypt server --port 9601 --host 0.0.0.0
Restart=on-failure
RestartSec=5
EnvironmentFile=-\$MEMBRANE_DIR/tower.env

[Install]
WantedBy=multi-user.target
SVC

cat > /etc/systemd/system/loamspine-membrane.service <<SVC
[Unit]
Description=loamSpine — permanent ledger (membrane)
After=network.target

[Service]
Type=simple
ExecStart=\$MEMBRANE_DIR/loamspine server --port 9700 --bind-address 0.0.0.0
Restart=on-failure
RestartSec=5
EnvironmentFile=-\$MEMBRANE_DIR/tower.env

[Install]
WantedBy=multi-user.target
SVC

cat > /etc/systemd/system/sweetgrass-membrane.service <<SVC
[Unit]
Description=sweetGrass — attribution braids (membrane)
After=network.target rhizocrypt-membrane.service loamspine-membrane.service
Wants=rhizocrypt-membrane.service loamspine-membrane.service

[Service]
Type=simple
ExecStart=\$MEMBRANE_DIR/sweetgrass server --port 0.0.0.0:9850
Restart=on-failure
RestartSec=5
EnvironmentFile=-\$MEMBRANE_DIR/tower.env

[Install]
WantedBy=multi-user.target
SVC

mkdir -p /var/lib/membrane/nestgate /var/lib/membrane/loamspine
NEST_UNITS

    log "  Opening firewall ports for Nest primals..."
    ssh "$remote" "ufw allow 9500/tcp comment 'NestGate storage' >/dev/null 2>&1" || true
    ssh "$remote" "ufw allow 9601/tcp comment 'rhizoCrypt DAG' >/dev/null 2>&1" || true
    ssh "$remote" "ufw allow 9700/tcp comment 'loamSpine ledger' >/dev/null 2>&1" || true
    ssh "$remote" "ufw allow 9850/tcp comment 'sweetGrass braids' >/dev/null 2>&1" || true

    log "  Enabling Nest services..."
    ssh "$remote" "systemctl daemon-reload"
    ssh "$remote" "systemctl enable nestgate-membrane rhizocrypt-membrane loamspine-membrane sweetgrass-membrane"
    ssh "$remote" "systemctl restart nestgate-membrane rhizocrypt-membrane loamspine-membrane sweetgrass-membrane" 2>/dev/null || true

    log ""
    log "  Nest expansion deployed."
    log "    NestGate:   /run/membrane/nestgate.sock   + :9500  (storage)"
    log "    rhizoCrypt: /run/membrane/rhizocrypt.sock + :9601  (DAG sessions)"
    log "    loamSpine:  /run/membrane/loamspine.sock  + :9700  (ledger)"
    log "    sweetGrass: /run/membrane/sweetgrass.sock + :9850  (attribution)"
}

status_nest_composition() {
    local remote="$1"

    log "Nest composition status:"
    for svc in nestgate-membrane rhizocrypt-membrane loamspine-membrane sweetgrass-membrane; do
        local state
        state=$(ssh "$remote" "systemctl is-active $svc 2>/dev/null || echo 'not-found'")
        local uptime
        uptime=$(ssh "$remote" "systemctl show $svc --property=ActiveEnterTimestamp 2>/dev/null | cut -d= -f2" || echo "unknown")
        log "  $svc: $state (since: $uptime)"
    done

    ssh "$remote" "ls -la /run/membrane/nestgate.sock /run/membrane/rhizocrypt.sock /run/membrane/loamspine.sock /run/membrane/sweetgrass.sock 2>/dev/null | sed 's/^/  Socket: /' || echo '  No Nest sockets found'"
    for port in 9500 9601 9700 9850; do
        ssh "$remote" "ss -tlnp 2>/dev/null | grep \":$port\" | sed 's/^/  Listening: /' || echo \"  Port $port: not listening\""
    done
}

# ── Node composition (compute tier) ─────────────────────────────────
# Wave 54: toadStool (compute dispatch), barraCuda (math/GPU), coralReef (shaders)

NODE_PRIMALS="toadstool barracuda coralreef"

deploy_node_composition() {
    local remote="$1"

    log "Node expansion: adding compute tier to composition"
    log "  Primals: $NODE_PRIMALS"

    if $DRY_RUN; then
        log "[dry-run] Would fetch toadstool, barracuda, coralreef from GitHub Releases"
        log "[dry-run] Would generate systemd units for Node primals"
        return 0
    fi

    ssh "$remote" "mkdir -p $REMOTE_MEMBRANE_DIR /run/membrane"

    for primal in $NODE_PRIMALS; do
        if ssh "$remote" "test -x $REMOTE_MEMBRANE_DIR/$primal" 2>/dev/null; then
            log "  $primal already present, skipping fetch"
        else
            remote_fetch_primal "$remote" "$primal"
        fi
    done

    ssh "$remote" "bash -s" <<NODE_UNITS
set -euo pipefail
MEMBRANE_DIR="$REMOTE_MEMBRANE_DIR"

cat > /etc/systemd/system/toadstool-membrane.service <<SVC
[Unit]
Description=ToadStool — compute dispatch (membrane)
After=network.target beardog-membrane.service
Wants=beardog-membrane.service

[Service]
Type=simple
ExecStart=\$MEMBRANE_DIR/toadstool server --socket /run/membrane/toadstool.sock
Restart=on-failure
RestartSec=5
EnvironmentFile=-\$MEMBRANE_DIR/tower.env

[Install]
WantedBy=multi-user.target
SVC

cat > /etc/systemd/system/barracuda-membrane.service <<SVC
[Unit]
Description=barraCuda — pure math (membrane)
After=network.target

[Service]
Type=simple
ExecStart=\$MEMBRANE_DIR/barracuda server --socket /run/membrane/barracuda.sock
Restart=on-failure
RestartSec=5
EnvironmentFile=-\$MEMBRANE_DIR/tower.env

[Install]
WantedBy=multi-user.target
SVC

cat > /etc/systemd/system/coralreef-membrane.service <<SVC
[Unit]
Description=coralReef — shader compilation (membrane)
After=network.target

[Service]
Type=simple
ExecStart=\$MEMBRANE_DIR/coralreef server --socket /run/membrane/coralreef.sock
Restart=on-failure
RestartSec=5
EnvironmentFile=-\$MEMBRANE_DIR/tower.env

[Install]
WantedBy=multi-user.target
SVC
NODE_UNITS

    ssh "$remote" "systemctl daemon-reload"
    ssh "$remote" "systemctl enable toadstool-membrane barracuda-membrane coralreef-membrane"
    ssh "$remote" "systemctl restart toadstool-membrane barracuda-membrane coralreef-membrane" 2>/dev/null || true

    log ""
    log "  Node tier deployed."
    log "    toadStool:  /run/membrane/toadstool.sock  (compute dispatch)"
    log "    barraCuda:  /run/membrane/barracuda.sock  (math)"
    log "    coralReef:  /run/membrane/coralreef.sock  (shaders)"
}

# ── Meta composition (orchestration tier) ──────────────────────────
# biomeOS (Neural API), Squirrel (AI), petalTongue (viz)

META_PRIMALS="biomeos squirrel petaltongue"

deploy_meta_composition() {
    local remote="$1"

    log "Meta expansion: adding orchestration tier"
    log "  Primals: $META_PRIMALS"

    if $DRY_RUN; then
        log "[dry-run] Would fetch biomeos, squirrel, petaltongue from GitHub Releases"
        log "[dry-run] Would generate systemd units for Meta primals"
        return 0
    fi

    ssh "$remote" "mkdir -p $REMOTE_MEMBRANE_DIR /run/membrane"

    for primal in $META_PRIMALS; do
        if ssh "$remote" "test -x $REMOTE_MEMBRANE_DIR/$primal" 2>/dev/null; then
            log "  $primal already present, skipping fetch"
        else
            remote_fetch_primal "$remote" "$primal"
        fi
    done

    ssh "$remote" "bash -s" <<META_UNITS
set -euo pipefail
MEMBRANE_DIR="$REMOTE_MEMBRANE_DIR"

cat > /etc/systemd/system/biomeos-membrane.service <<SVC
[Unit]
Description=biomeOS — Neural API orchestrator (membrane)
After=network.target beardog-membrane.service songbird-relay.service
Wants=beardog-membrane.service songbird-relay.service

[Service]
Type=simple
ExecStart=\$MEMBRANE_DIR/biomeos api --socket /run/membrane/biomeos.sock
Restart=on-failure
RestartSec=5
EnvironmentFile=-\$MEMBRANE_DIR/tower.env
Environment=BIOMEOS_BTSP_ENFORCE=0

[Install]
WantedBy=multi-user.target
SVC

cat > /etc/systemd/system/squirrel-membrane.service <<SVC
[Unit]
Description=Squirrel — AI coordination (membrane)
After=network.target biomeos-membrane.service

[Service]
Type=simple
ExecStart=\$MEMBRANE_DIR/squirrel server --socket /run/membrane/squirrel.sock
Restart=on-failure
RestartSec=5
EnvironmentFile=-\$MEMBRANE_DIR/tower.env

[Install]
WantedBy=multi-user.target
SVC

cat > /etc/systemd/system/petaltongue-membrane.service <<SVC
[Unit]
Description=petalTongue — visualization (membrane)
After=network.target biomeos-membrane.service

[Service]
Type=simple
ExecStart=\$MEMBRANE_DIR/petaltongue server --socket /run/membrane/petaltongue.sock
Restart=on-failure
RestartSec=5
EnvironmentFile=-\$MEMBRANE_DIR/tower.env

[Install]
WantedBy=multi-user.target
SVC
META_UNITS

    ssh "$remote" "systemctl daemon-reload"
    ssh "$remote" "systemctl enable biomeos-membrane squirrel-membrane petaltongue-membrane"
    ssh "$remote" "systemctl restart biomeos-membrane squirrel-membrane petaltongue-membrane" 2>/dev/null || true

    log ""
    log "  Meta tier deployed."
    log "    biomeOS:     /run/membrane/biomeos.sock     (Neural API)"
    log "    Squirrel:    /run/membrane/squirrel.sock    (AI)"
    log "    petalTongue: /run/membrane/petaltongue.sock (viz)"
}

# ── RustDesk co-host deployment ──────────────────────────────────────
# Installs hbbs (rendezvous) and hbbr (relay) alongside Songbird.
# RustDesk is an AGPL-3.0 symbiotic partner providing sovereign remote
# desktop for geo-delocalized gates.

RUSTDESK_VER_FROM_MANIFEST=$(grep -A5 '^\[membrane.rustdesk\]' "$SCRIPT_DIR/manifest.toml" 2>/dev/null \
    | grep '^version' | head -1 | sed 's/.*= *"\(.*\)"/\1/' || true)
RUSTDESK_VER="${RUSTDESK_VER_FROM_MANIFEST:-1.1.15}"
RUSTDESK_URL="https://github.com/rustdesk/rustdesk-server/releases/download/${RUSTDESK_VER}/rustdesk-server-linux-amd64.zip"

deploy_rustdesk() {
    local remote="$1"

    log "Deploying RustDesk server (hbbs + hbbr) v${RUSTDESK_VER}..."

    if $DRY_RUN; then
        log "[dry-run] Would download RustDesk server from GitHub"
        log "[dry-run] Would install hbbs + hbbr to /opt/membrane/"
        log "[dry-run] Would create systemd units"
        return 0
    fi

    ssh "$remote" "bash -s" <<RDEPLOY
set -euo pipefail
mkdir -p /opt/membrane/rustdesk
cd /tmp
command -v unzip >/dev/null 2>&1 || apt-get install -y -qq unzip >/dev/null 2>&1
curl -fsSL "${RUSTDESK_URL}" -o rustdesk-server.zip
unzip -o rustdesk-server.zip -d rustdesk-extract
find rustdesk-extract -name 'hbbs' -type f -exec cp {} /opt/membrane/hbbs \;
find rustdesk-extract -name 'hbbr' -type f -exec cp {} /opt/membrane/hbbr \;
chmod +x /opt/membrane/hbbs /opt/membrane/hbbr
rm -rf /tmp/rustdesk-server.zip /tmp/rustdesk-extract
echo "RustDesk binaries installed."
RDEPLOY

    log "  Installing systemd units..."
    scp "${MEMBRANE_DIR}/hbbs-membrane.service" "$remote:/etc/systemd/system/"
    scp "${MEMBRANE_DIR}/hbbr-membrane.service" "$remote:/etc/systemd/system/"
    ssh "$remote" "systemctl daemon-reload && systemctl enable --now hbbs-membrane && sleep 2 && systemctl enable --now hbbr-membrane"

    local pubkey
    pubkey=$(ssh "$remote" "cat /opt/membrane/rustdesk/id_ed25519.pub 2>/dev/null || echo 'not-generated-yet'")
    log "  RustDesk deployed."
    log "  Public key: $pubkey"
    log ""
    log "  Client config: set ID Server and Relay Server to $(echo "$remote" | cut -d@ -f2)"
    log "  Paste this public key into the RustDesk client 'Key' field."
}

status_rustdesk() {
    local remote="$1"

    log "RustDesk status:"
    for svc in hbbs-membrane hbbr-membrane; do
        local state
        state=$(ssh "$remote" "systemctl is-active $svc 2>/dev/null || echo 'not-found'")
        log "  $svc: $state"
    done

    local pubkey
    pubkey=$(ssh "$remote" "cat /opt/membrane/rustdesk/id_ed25519.pub 2>/dev/null || echo 'absent'")
    log "  Public key: $pubkey"

    ssh "$remote" "ss -tlnp 2>/dev/null | grep -E ':(21115|21116|21117)' | sed 's/^/  Listening: /' || echo '  RustDesk ports: not listening'"
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
    log "│   Composition: $COMPOSITION"
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

    log "Deploying membrane to $REMOTE"
    log "  Composition: $COMPOSITION"
    log "  Model A: all channels on single VPS"
    log ""

    ssh "$REMOTE" "apt-get update -qq && apt-get install -y -qq ufw xxd curl >/dev/null 2>&1" 2>/dev/null || true

    harden_ssh "$REMOTE"
    deploy_firewall "$REMOTE"

    case "$COMPOSITION" in
        relay)
            deploy_channel_2_relay "$REMOTE"
            ;;
        tower)
            deploy_tower_composition "$REMOTE"
            deploy_rustdesk "$REMOTE"
            ;;
        nest)
            deploy_tower_composition "$REMOTE"
            deploy_rustdesk "$REMOTE"
            deploy_nest_composition "$REMOTE"
            ;;
        nucleus)
            deploy_tower_composition "$REMOTE"
            deploy_rustdesk "$REMOTE"
            deploy_node_composition "$REMOTE"
            deploy_nest_composition "$REMOTE"
            deploy_meta_composition "$REMOTE"
            ;;
        rustdesk)
            deploy_channel_2_relay "$REMOTE"
            deploy_rustdesk "$REMOTE"
            ;;
        *)
            die "Unknown composition: $COMPOSITION. Use relay, tower, nest, nucleus, or rustdesk."
            ;;
    esac

    log ""
    if $VALIDATE_AFTER; then
        log "Running post-deploy verification..."
        log ""
        verify_composition "$REMOTE"
    else
        log "Deployment complete. Run status to verify:"
        log "  ./deploy_membrane.sh status $REMOTE"
        log "  (or add --validate to deploy for automatic post-deploy checks)"
    fi
}

# ── Mode: status ─────────────────────────────────────────────────────

verify_composition() {
    local remote="$1"
    local verify_fail=0

    log "Composition verification:"

    local check_primals="beardog songbird skunkbat"
    if ssh "$remote" "test -x /opt/membrane/nestgate" 2>/dev/null; then
        check_primals="beardog songbird skunkbat nestgate rhizocrypt loamspine sweetgrass"
    fi

    for primal in $check_primals; do
        local bin_path="/opt/membrane/$primal"
        local exists
        exists=$(ssh "$remote" "test -x '$bin_path' && echo yes || echo no")
        if [[ "$exists" == "yes" ]]; then
            local version
            version=$(ssh "$remote" "'$bin_path' --version 2>/dev/null || echo 'unknown'")
            log "  $primal: present ($version)"
        else
            log "  $primal: MISSING"
            verify_fail=$((verify_fail + 1))
        fi
    done

    local ufw_pattern="22/tcp|3478|21115|21116|21117|80/tcp|443/tcp"
    if ssh "$remote" "test -x /opt/membrane/nestgate" 2>/dev/null; then
        ufw_pattern="$ufw_pattern|9500|9601|9700|9850"
    fi
    local ufw_rules
    ufw_rules=$(ssh "$remote" "ufw status 2>/dev/null | grep -cE '$ufw_pattern' || echo 0")
    log "  UFW rules matching composition: $ufw_rules"

    local unexpected
    unexpected=$(ssh "$remote" "ufw status 2>/dev/null | grep ALLOW | grep -cvE '$ufw_pattern' || echo 0")
    if [[ "$unexpected" -gt 0 ]]; then
        log "  WARNING: $unexpected UFW rules outside expected composition ports"
    fi

    local check_svcs="beardog-membrane songbird-relay skunkbat-membrane"
    if ssh "$remote" "test -x /opt/membrane/nestgate" 2>/dev/null; then
        check_svcs="$check_svcs nestgate-membrane rhizocrypt-membrane loamspine-membrane sweetgrass-membrane"
    fi
    for svc in $check_svcs; do
        local active
        active=$(ssh "$remote" "systemctl is-active $svc 2>/dev/null || echo inactive")
        if [[ "$active" != "active" ]]; then
            log "  WARNING: $svc is $active"
            verify_fail=$((verify_fail + 1))
        fi
    done

    if [[ "$verify_fail" -eq 0 ]]; then
        log "  Composition verification: ALL PASS"
    else
        log "  Composition verification: $verify_fail issue(s)"
    fi
}

do_status() {
    [[ -n "$REMOTE" ]] || die "No remote specified. Usage: deploy_membrane.sh status root@<ip>"

    log "Membrane status for $REMOTE"
    log ""

    local has_tower
    has_tower=$(ssh "$REMOTE" "test -f /etc/systemd/system/beardog-membrane.service && echo yes || echo no")
    local has_rustdesk
    has_rustdesk=$(ssh "$REMOTE" "test -f /etc/systemd/system/hbbs-membrane.service && echo yes || echo no")

    if [[ "$has_tower" == "yes" ]]; then
        status_tower_composition "$REMOTE"
    else
        status_channel_2_relay "$REMOTE"
    fi

    local has_nest
    has_nest=$(ssh "$REMOTE" "test -f /etc/systemd/system/nestgate-membrane.service && echo yes || echo no")
    if [[ "$has_nest" == "yes" ]]; then
        log ""
        status_nest_composition "$REMOTE"
    fi

    if [[ "$has_rustdesk" == "yes" ]]; then
        log ""
        status_rustdesk "$REMOTE"
    fi

    log ""
    if [[ "$has_tower" == "yes" ]]; then
        verify_composition "$REMOTE"
        log ""
    fi

    log "Channel 1 (Signal/DNS): not yet deployed"
    log "Channel 3 (Surface/TLS): not yet deployed"

    local cred_age
    cred_age=$(ssh "$REMOTE" "test -f /opt/membrane/credentials.age && echo 'present' || echo 'absent'")
    log "Credential blob (age-encrypted): $cred_age"
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

# ── Mode: keys ───────────────────────────────────────────────────────
# Multi-gate SSH key management. Each authorized key gets a tagged
# comment for audit: "# gate:<name> added:<date>"

do_keys() {
    [[ -n "$REMOTE" ]] || die "No remote specified. Usage: deploy_membrane.sh keys <add|list|revoke> root@<ip> [options]"
    local action="${KEYS_ACTION:-list}"

    case "$action" in
        add)
            [[ -n "${KEY_NAME:-}" ]] || die "No --name specified for key"
            [[ -n "${KEY_PUBKEY:-}" ]] || die "No --pubkey specified"
            local tag="# gate:${KEY_NAME} added:$(date +%Y-%m-%d)"

            if ssh "$REMOTE" "grep -q '${KEY_NAME}' /root/.ssh/authorized_keys 2>/dev/null"; then
                log "Key for '$KEY_NAME' already authorized."
                return 0
            fi

            log "Authorizing key for gate: $KEY_NAME"
            ssh "$REMOTE" "echo '${KEY_PUBKEY} ${tag}' >> /root/.ssh/authorized_keys"
            log "  Key added. Tag: $tag"
            ;;
        list)
            log "Authorized keys on $REMOTE:"
            ssh "$REMOTE" "cat /root/.ssh/authorized_keys" | while IFS= read -r line; do
                local comment
                comment=$(echo "$line" | awk '{for(i=3;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/ *$//')
                local keytype
                keytype=$(echo "$line" | awk '{print $1}')
                local fingerprint
                fingerprint=$(echo "$line" | awk '{print $2}' | head -c 20)
                log "  ${keytype} ...${fingerprint}...  ${comment}"
            done
            ;;
        revoke)
            [[ -n "${KEY_NAME:-}" ]] || die "No --name specified for revocation"
            log "Revoking key for gate: $KEY_NAME"
            ssh "$REMOTE" "sed -i '/${KEY_NAME}/d' /root/.ssh/authorized_keys"
            log "  Key revoked."
            ;;
        *)
            die "Unknown keys action: $action. Use add, list, or revoke."
            ;;
    esac
}

# ── Argument parsing ─────────────────────────────────────────────────

[[ $# -ge 1 ]] || { usage; exit 1; }

MODE="$1"; shift

KEYS_ACTION=""
KEY_NAME=""
KEY_PUBKEY=""

if [[ "$MODE" == "keys" && $# -ge 1 && "$1" != --* && "$1" != *@* ]]; then
    KEYS_ACTION="$1"; shift
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --region)        DROPLET_REGION="$2"; shift 2 ;;
        --size)          DROPLET_SIZE="$2"; shift 2 ;;
        --name)          if [[ "$MODE" == "keys" ]]; then KEY_NAME="$2"; else DROPLET_NAME="$2"; fi; shift 2 ;;
        --pubkey)        KEY_PUBKEY="$2"; shift 2 ;;
        --ssh-key)       SSH_KEY_FINGERPRINT="$2"; shift 2 ;;
        --composition)   COMPOSITION="$2"; shift 2 ;;
        --validate)      VALIDATE_AFTER=true; shift ;;
        --dry-run)       DRY_RUN=true; shift ;;
        --help)          usage; exit 0 ;;
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
    keys)      do_keys ;;
    teardown)  do_teardown ;;
    --help)    usage ;;
    *)         die "Unknown mode: $MODE. Use provision, deploy, status, keys, or teardown." ;;
esac
