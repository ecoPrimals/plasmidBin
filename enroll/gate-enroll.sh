#!/usr/bin/env bash
# gate-enroll.sh — Zero-operator autonomous gate enrollment
#
# A new gate runs this script to self-enroll into the ecoPrimals mesh.
# It contacts golgiBody's enrollment endpoint, receives provisioning
# credentials, and bootstraps itself into the ecosystem.
#
# Trust escalation (K-Derm model):
#   Extracellular → Outer Membrane → Periplasm → Inner Membrane → Cytoplasm
#
# Usage:
#   ./gate-enroll.sh --hub primals.eco --token <enrollment-token>
#   ./gate-enroll.sh --hub primals.eco --fido2 <credential-id>
#   ./gate-enroll.sh --hub 157.230.3.183 --token <token> --gate myGate
#
# Prerequisites: curl, wireguard-tools, ssh-keygen, git, jq
# Run as root (or with sudo for WireGuard setup).

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────

HUB_HOST="${HUB_HOST:-primals.eco}"
HUB_PORT="${HUB_PORT:-7780}"
GATE_NAME="${GATE_NAME:-$(hostname)}"
PROOF_TYPE="token"
PROOF_VALUE=""
COMPOSITION="full"
WG_IFACE="wg0"
WG_DIR="/etc/wireguard"
SSH_KEY_PATH="$HOME/.ssh/id_ed25519"
ECO_ROOT="$HOME/Development/ecoPrimals"
FORGEJO_GIT_ADDR="10.13.37.1:2222"
FORGEJO_ORG="ecoPrimals"

# ── Argument parsing ─────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --hub)        HUB_HOST="$2"; shift 2 ;;
        --port)       HUB_PORT="$2"; shift 2 ;;
        --gate)       GATE_NAME="$2"; shift 2 ;;
        --token)      PROOF_TYPE="token"; PROOF_VALUE="$2"; shift 2 ;;
        --fido2)      PROOF_TYPE="fido2"; PROOF_VALUE="$2"; shift 2 ;;
        --beacon)     PROOF_TYPE="beacon"; PROOF_VALUE="$2"; shift 2 ;;
        --compose)    COMPOSITION="$2"; shift 2 ;;
        --eco-root)   ECO_ROOT="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 --hub <host> --token <enrollment-token> [--gate <name>]"
            echo ""
            echo "Options:"
            echo "  --hub <host>       Enrollment hub hostname or IP (default: primals.eco)"
            echo "  --port <port>      Enrollment hub port (default: 7780)"
            echo "  --gate <name>      Gate name (default: hostname)"
            echo "  --token <token>    Pre-shared enrollment token"
            echo "  --fido2 <cred_id>  FIDO2 credential ID for attestation"
            echo "  --beacon <id>      Beacon ID for proximity proof"
            echo "  --compose <type>   Composition type: full, relay, compute (default: full)"
            echo "  --eco-root <path>  Ecosystem root directory (default: ~/Development/ecoPrimals)"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ -z "$PROOF_VALUE" ]]; then
    echo "Error: enrollment proof required. Use --token, --fido2, or --beacon."
    echo "Run '$0 --help' for usage."
    exit 1
fi

# ── Colors ────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

phase() { echo -e "\n${CYAN}${BOLD}[$1]${NC} $2"; }
ok()    { echo -e "  ${GREEN}✓${NC} $1"; }
warn()  { echo -e "  ${YELLOW}⚠${NC} $1"; }
fail()  { echo -e "  ${RED}✗${NC} $1"; }

echo -e "${BOLD}ecoPrimals Autonomous Gate Enrollment${NC}"
echo -e "Gate: ${CYAN}${GATE_NAME}${NC}  Hub: ${CYAN}${HUB_HOST}:${HUB_PORT}${NC}  Proof: ${CYAN}${PROOF_TYPE}${NC}"
echo ""

# ── Phase 1: Prerequisites ───────────────────────────────────────

phase "1/7" "Checking prerequisites"

for cmd in curl jq git; do
    if command -v "$cmd" &>/dev/null; then
        ok "$cmd available"
    else
        fail "$cmd not found — install it first"
        exit 1
    fi
done

if ! command -v wg &>/dev/null; then
    warn "wireguard-tools not found — installing..."
    if command -v apt &>/dev/null; then
        sudo apt install -y wireguard-tools
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y wireguard-tools
    else
        fail "Cannot install wireguard-tools — install manually"
        exit 1
    fi
fi
ok "wireguard-tools available"

# ── Phase 2: Generate WireGuard keypair ──────────────────────────

phase "2/7" "Generating WireGuard keypair"

if [[ -f "$WG_DIR/privatekey" ]]; then
    WG_PRIVKEY=$(cat "$WG_DIR/privatekey")
    WG_PUBKEY=$(echo "$WG_PRIVKEY" | wg pubkey)
    ok "existing keypair found (pub: ${WG_PUBKEY:0:12}...)"
else
    sudo mkdir -p "$WG_DIR"
    WG_PRIVKEY=$(wg genkey)
    echo "$WG_PRIVKEY" | sudo tee "$WG_DIR/privatekey" > /dev/null
    sudo chmod 600 "$WG_DIR/privatekey"
    WG_PUBKEY=$(echo "$WG_PRIVKEY" | wg pubkey)
    echo "$WG_PUBKEY" | sudo tee "$WG_DIR/publickey" > /dev/null
    ok "keypair generated (pub: ${WG_PUBKEY:0:12}...)"
fi

# ── Phase 3: Generate SSH keypair ────────────────────────────────

phase "3/7" "Generating SSH keypair"

if [[ -f "$SSH_KEY_PATH" ]]; then
    SSH_PUBKEY=$(cat "${SSH_KEY_PATH}.pub")
    ok "existing SSH key found"
else
    ssh-keygen -t ed25519 -C "${GATE_NAME}@primals.eco" -f "$SSH_KEY_PATH" -N ""
    SSH_PUBKEY=$(cat "${SSH_KEY_PATH}.pub")
    ok "SSH key generated"
fi

# ── Phase 4: Contact enrollment endpoint ─────────────────────────

phase "4/7" "Contacting enrollment endpoint at ${HUB_HOST}:${HUB_PORT}"

# Build the physical proof JSON
case "$PROOF_TYPE" in
    token)
        PROOF_JSON="{\"type\":\"token\",\"token\":\"${PROOF_VALUE}\"}"
        ;;
    fido2)
        # In production, this would call beardog.fido2.attest_enrollment
        # locally and send the attestation blob
        PROOF_JSON="{\"type\":\"fido2\",\"credential_id\":\"${PROOF_VALUE}\",\"attestation\":\"pending\"}"
        ;;
    beacon)
        PROOF_JSON="{\"type\":\"beacon_proximity\",\"beacon_id\":\"${PROOF_VALUE}\",\"challenge_response\":\"pending\"}"
        ;;
esac

REQUEST_BODY=$(jq -n \
    --arg gate "$GATE_NAME" \
    --arg wg_key "$WG_PUBKEY" \
    --arg ssh_key "$SSH_PUBKEY" \
    --argjson proof "$PROOF_JSON" \
    --arg comp "$COMPOSITION" \
    '{
        gate_name: $gate,
        wg_public_key: $wg_key,
        ssh_public_key: $ssh_key,
        physical_proof: $proof,
        composition: $comp
    }')

RESPONSE=$(curl -s -m 30 \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$REQUEST_BODY" \
    "http://${HUB_HOST}:${HUB_PORT}/enroll/mesh.gate_enroll" 2>&1) || {
    fail "Cannot reach enrollment endpoint at ${HUB_HOST}:${HUB_PORT}"
    echo "  Response: $RESPONSE"
    echo ""
    echo "Ensure golgiBody is running with the Drawbridge enrollment route enabled."
    echo "Set SONGBIRD_DRAWBRIDGE_ROUTES=/enroll=mesh!public"
    exit 1
}

ENROLLED=$(echo "$RESPONSE" | jq -r '.result.enrolled // .enrolled // "false"')
MESH_IP=$(echo "$RESPONSE" | jq -r '.result.mesh_ip // .mesh_ip // empty')

if [[ "$ENROLLED" != "true" ]]; then
    REASON=$(echo "$RESPONSE" | jq -r '.result.reason // .reason // "unknown"')
    fail "Enrollment rejected: $REASON"
    echo ""
    echo "Phases:"
    echo "$RESPONSE" | jq -r '(.result.phases // .phases // [])[] | "  \(if .ok then "✓" else "✗" end) \(.name): \(.detail)"'
    exit 1
fi

ok "Enrolled! Mesh IP: ${MESH_IP}"

# ── Phase 5: Configure WireGuard ─────────────────────────────────

phase "5/7" "Configuring WireGuard"

HUB_ENDPOINT=$(echo "$RESPONSE" | jq -r '.result.wg_config.hub_endpoint // empty')
HUB_PUBKEY=$(echo "$RESPONSE" | jq -r '.result.wg_config.hub_public_key // empty')
SUBNET=$(echo "$RESPONSE" | jq -r '.result.wg_config.subnet // "10.13.37.0/24"')
DNS=$(echo "$RESPONSE" | jq -r '.result.wg_config.dns // "10.13.37.1"')

if [[ -n "$HUB_ENDPOINT" && -n "$HUB_PUBKEY" ]]; then
    sudo tee "$WG_DIR/$WG_IFACE.conf" > /dev/null <<EOF
[Interface]
PrivateKey = ${WG_PRIVKEY}
Address = ${MESH_IP}/24
DNS = ${DNS}

[Peer]
PublicKey = ${HUB_PUBKEY}
Endpoint = ${HUB_ENDPOINT}
AllowedIPs = ${SUBNET}
PersistentKeepalive = 25
EOF
    sudo chmod 600 "$WG_DIR/$WG_IFACE.conf"
    ok "WireGuard config written to $WG_DIR/$WG_IFACE.conf"

    sudo wg-quick up "$WG_IFACE" 2>/dev/null || sudo systemctl restart "wg-quick@${WG_IFACE}" 2>/dev/null || true

    if ping -c 1 -W 3 "$DNS" &>/dev/null; then
        ok "Mesh connectivity verified (hub reachable)"
    else
        warn "Hub not yet reachable — WireGuard may need a moment"
    fi
else
    warn "No WG config in response — configure manually"
fi

# ── Phase 6: Configure Forgejo SSH + git remotes ─────────────────

phase "6/7" "Configuring Forgejo-first git remotes"

mkdir -p "$HOME/.ssh"
if ! grep -q "Host forgejo" "$HOME/.ssh/config" 2>/dev/null; then
    cat >> "$HOME/.ssh/config" <<EOF

Host forgejo
    HostName ${DNS}
    Port 2222
    User git
    IdentityFile ${SSH_KEY_PATH}
    StrictHostKeyChecking accept-new
EOF
    ok "SSH config for Forgejo added"
else
    ok "SSH config for Forgejo already exists"
fi

# Set up ecosystem root
mkdir -p "$ECO_ROOT"
ok "Ecosystem root: $ECO_ROOT"

# ── Phase 7: Save family seed (if delivered) ─────────────────────

phase "7/7" "Finalizing enrollment"

ENCRYPTED_SEED=$(echo "$RESPONSE" | jq -r '.result.family_seed_encrypted // empty')
if [[ -n "$ENCRYPTED_SEED" ]]; then
    mkdir -p "$HOME/.config/ecoPrimals"
    echo "$ENCRYPTED_SEED" > "$HOME/.config/ecoPrimals/family_seed.enc"
    chmod 600 "$HOME/.config/ecoPrimals/family_seed.enc"
    ok "Family seed saved (encrypted)"
else
    warn "No family seed delivered — request manually or re-enroll"
fi

# ── Summary ───────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  Gate ${GATE_NAME} enrolled successfully!${NC}"
echo -e "${GREEN}${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Mesh IP:     ${CYAN}${MESH_IP}${NC}"
echo -e "  WG Iface:    ${CYAN}${WG_IFACE}${NC}"
echo -e "  Hub:         ${CYAN}${HUB_ENDPOINT:-unknown}${NC}"
echo -e "  Forgejo:     ${CYAN}ssh://git@${DNS}:2222${NC}"
echo -e "  Eco Root:    ${CYAN}${ECO_ROOT}${NC}"
echo ""
echo -e "Next steps:"
echo -e "  1. Clone repos:  ${YELLOW}cd ${ECO_ROOT} && for r in primals springs infra gardens; do"
echo -e "       ssh -T forgejo 2>&1 | head -1  # verify Forgejo access"
echo -e "     done${NC}"
echo -e "  2. Build:        ${YELLOW}for p in primals/*/; do (cd \"\$p\" && cargo build --release); done${NC}"
echo -e "  3. Validate:     ${YELLOW}cd springs/primalSpring && cargo test --release${NC}"
echo ""
echo -e "Or let the agent take over: the gate is now reachable via mesh at ${MESH_IP}"
