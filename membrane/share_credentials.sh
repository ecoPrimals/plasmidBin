#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# membrane/share_credentials.sh — Encrypt/decrypt membrane credentials via age
#
# Uses age encryption with SSH ed25519 public keys to share credentials
# between gates. Any gate with the same SSH private key can decrypt.
# This is the SHORT TERM solution (established tooling, zero custom code)
# for the "leave a key, pick it up from another system" pattern.
#
# See: wateringHole/MEMBRANE_CHANNEL_ARCHITECTURE.md (Credential Sharing)
#
# Usage:
#   ./share_credentials.sh encrypt                    # Encrypt credentials to age blob
#   ./share_credentials.sh encrypt --recipient ~/.ssh/id_ed25519.pub
#   ./share_credentials.sh decrypt                    # Decrypt with local SSH key
#   ./share_credentials.sh decrypt --identity ~/.ssh/id_ed25519
#   ./share_credentials.sh push root@<vps-ip>         # Encrypt + SCP to membrane VPS
#   ./share_credentials.sh pull root@<vps-ip>         # Fetch from VPS + decrypt
#   ./share_credentials.sh show                       # Decrypt and display (no file write)
#
# Prerequisites:
#   - age (apt install age / brew install age)
#   - SSH ed25519 key pair (~/.ssh/id_ed25519 + .pub)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CREDENTIALS_FILE="$SCRIPT_DIR/membrane-credentials.age"
DEFAULT_PUBKEY="$HOME/.ssh/id_ed25519.pub"
DEFAULT_IDENTITY="$HOME/.ssh/id_ed25519"
REMOTE_CRED_PATH="/opt/membrane/credentials.age"

log()  { echo "[share] $*"; }
die()  { echo "[share] ERROR: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: share_credentials.sh <mode> [options]

Modes:
  encrypt              Encrypt credentials to age blob (interactive)
  decrypt              Decrypt age blob to stdout
  push <user@host>     Encrypt + upload to membrane VPS
  pull <user@host>     Download from VPS + decrypt locally
  show                 Decrypt and display without writing files

Options:
  --recipient PATH     SSH public key to encrypt to (default: ~/.ssh/id_ed25519.pub)
  --identity PATH      SSH private key for decryption (default: ~/.ssh/id_ed25519)
  --file PATH          Age-encrypted file path (default: membrane/membrane-credentials.age)
  --help               Show this help

The encrypted blob can be safely stored on the VPS, in git, or transferred
between machines. Only holders of the corresponding SSH private key can decrypt.

Evolution path:
  SHORT TERM:  age + SSH keys (this script) — established, zero custom code
  MID TERM:    BearDog secrets.store via BTSP — identity-based, no file sharing
  LONG TERM:   Membrane Tower auto-rotates credentials autonomously
EOF
}

do_encrypt() {
    local pubkey="$1"

    command -v age >/dev/null 2>&1 || die "age not installed. Run: apt install age"
    [[ -f "$pubkey" ]] || die "SSH public key not found: $pubkey"

    log "Encrypting membrane credentials"
    log "  Recipient: $pubkey"
    log ""
    log "Enter credentials (Ctrl-D when done):"
    log "  Format: KEY=value, one per line"
    log "  Expected keys: DOCTL_TOKEN, SONGBIRD_TURN_KEY, SONGBIRD_TURN_USERNAME"
    log "  Optional: VPS_IP, DROPLET_NAME, SSH_KEY_FINGERPRINT"
    log ""

    age -R "$pubkey" -o "$CREDENTIALS_FILE" -

    log ""
    log "Encrypted to: $CREDENTIALS_FILE"
    log "  Size: $(du -h "$CREDENTIALS_FILE" | cut -f1)"
    log "  Decrypt with: $0 decrypt"
    log "  Push to VPS:  $0 push root@<ip>"
}

do_encrypt_env() {
    local pubkey="$1"
    local doctl_token="${DOCTL_TOKEN:-}"
    local turn_key="${SONGBIRD_TURN_KEY:-}"
    local turn_user="${SONGBIRD_TURN_USERNAME:-nucleus-relay}"
    local vps_ip="${MEMBRANE_VPS_IP:-}"

    command -v age >/dev/null 2>&1 || die "age not installed. Run: apt install age"
    [[ -f "$pubkey" ]] || die "SSH public key not found: $pubkey"

    if [[ -z "$doctl_token" ]]; then
        if [[ -f "$HOME/.config/doctl/token" ]]; then
            doctl_token=$(cat "$HOME/.config/doctl/token")
        fi
    fi

    [[ -n "$doctl_token" ]] || die "No DOCTL_TOKEN env var and no ~/.config/doctl/token file"

    if [[ -z "$vps_ip" ]]; then
        vps_ip=$(doctl compute droplet list --tag-name membrane --format PublicIPv4 --no-header 2>/dev/null | head -1) || vps_ip=""
    fi

    if [[ -z "$turn_key" && -n "$vps_ip" ]]; then
        turn_key=$(ssh "root@$vps_ip" "grep SONGBIRD_TURN_KEY /opt/membrane/credentials.env 2>/dev/null | cut -d= -f2" 2>/dev/null) || turn_key=""
    fi

    log "Encrypting membrane credentials from environment/config"
    log "  Recipient: $pubkey"
    log "  DOCTL_TOKEN: ${doctl_token:0:12}..."
    log "  SONGBIRD_TURN_KEY: ${turn_key:0:12}..."
    log "  MEMBRANE_VPS_IP: ${vps_ip:-unknown}"

    age -R "$pubkey" -o "$CREDENTIALS_FILE" <<CREDS
# Membrane credentials — encrypted with age to SSH ed25519 pubkey
# Decrypt: age -d -i ~/.ssh/id_ed25519 membrane-credentials.age
# Generated: $(date -Iseconds)
DOCTL_TOKEN=$doctl_token
SONGBIRD_TURN_KEY=$turn_key
SONGBIRD_TURN_USERNAME=$turn_user
MEMBRANE_VPS_IP=$vps_ip
CREDS

    log "  Written: $CREDENTIALS_FILE ($(du -h "$CREDENTIALS_FILE" | cut -f1))"
}

do_decrypt() {
    local identity="$1"
    local output_file="${2:-}"

    command -v age >/dev/null 2>&1 || die "age not installed"
    [[ -f "$CREDENTIALS_FILE" ]] || die "No encrypted credentials at $CREDENTIALS_FILE"
    [[ -f "$identity" ]] || die "SSH private key not found: $identity"

    if [[ -n "$output_file" ]]; then
        age -d -i "$identity" "$CREDENTIALS_FILE" > "$output_file"
        chmod 600 "$output_file"
        log "Decrypted to: $output_file"
    else
        age -d -i "$identity" "$CREDENTIALS_FILE"
    fi
}

do_push() {
    local remote="$1"
    local pubkey="$2"

    if [[ ! -f "$CREDENTIALS_FILE" ]]; then
        log "No local credentials file — encrypting from environment first"
        do_encrypt_env "$pubkey"
    fi

    log "Pushing encrypted credentials to $remote:$REMOTE_CRED_PATH"
    scp -q "$CREDENTIALS_FILE" "$remote:$REMOTE_CRED_PATH"
    ssh "$remote" "chmod 600 $REMOTE_CRED_PATH"
    log "  Pushed. Remote gate can decrypt with: age -d -i ~/.ssh/id_ed25519 $REMOTE_CRED_PATH"
}

do_pull() {
    local remote="$1"
    local identity="$2"

    log "Pulling encrypted credentials from $remote:$REMOTE_CRED_PATH"
    scp -q "$remote:$REMOTE_CRED_PATH" "$CREDENTIALS_FILE"

    log "Decrypting..."
    do_decrypt "$identity"
}

# ── Argument parsing ─────────────────────────────────────────────────

[[ $# -ge 1 ]] || { usage; exit 1; }

MODE="$1"; shift
RECIPIENT="$DEFAULT_PUBKEY"
IDENTITY="$DEFAULT_IDENTITY"
REMOTE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --recipient) RECIPIENT="$2"; shift 2 ;;
        --identity)  IDENTITY="$2"; shift 2 ;;
        --file)      CREDENTIALS_FILE="$2"; shift 2 ;;
        --help)      usage; exit 0 ;;
        *)
            if [[ -z "$REMOTE" && "$1" == *@* ]]; then
                REMOTE="$1"; shift
            else
                die "Unknown option: $1"
            fi
            ;;
    esac
done

case "$MODE" in
    encrypt)
        if [[ -t 0 ]]; then
            do_encrypt "$RECIPIENT"
        else
            do_encrypt_env "$RECIPIENT"
        fi
        ;;
    decrypt)
        do_decrypt "$IDENTITY"
        ;;
    show)
        do_decrypt "$IDENTITY"
        ;;
    push)
        [[ -n "$REMOTE" ]] || die "Usage: share_credentials.sh push root@<ip>"
        do_push "$REMOTE" "$RECIPIENT"
        ;;
    pull)
        [[ -n "$REMOTE" ]] || die "Usage: share_credentials.sh pull root@<ip>"
        do_pull "$REMOTE" "$IDENTITY"
        ;;
    --help)
        usage
        ;;
    *)
        die "Unknown mode: $MODE. Use encrypt, decrypt, push, pull, or show."
        ;;
esac
