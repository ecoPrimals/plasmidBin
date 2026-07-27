#!/usr/bin/env bash
# enroll-fleet.sh — Run on each enrolling gate via RustDesk
#
# Fetches gate-enroll.sh from golgiBody and runs enrollment.
# One-liner for the operator: curl + bash.
#
# Usage (from any enrolling gate):
#   curl -sL https://primals.eco/depot/enroll/enroll-fleet.sh | bash -s -- <gate_name>
#
# Or with direct WAN IP:
#   curl -sL http://157.230.3.183:7780/depot/enroll/enroll-fleet.sh | bash -s -- <gate_name>

set -euo pipefail

GATE_NAME="${1:?Usage: $0 <gate_name> (e.g. southGate, strandGate, westGate, blueGate, swiftGate)}"
HUB="primals.eco"
TOKEN="451d897bf69484712e307b3def7510dd04daad032cb00816e11987bbf85e7ac1"

case "$GATE_NAME" in
    southGate)  COMPOSE="full" ;;
    strandGate) COMPOSE="compute" ;;
    westGate)   COMPOSE="nest" ;;
    blueGate)   COMPOSE="tower" ;;
    swiftGate)  COMPOSE="full" ;;
    *) echo "Unknown gate: $GATE_NAME"; exit 1 ;;
esac

echo "=== Fleet Enrollment: $GATE_NAME (composition: $COMPOSE) ==="
echo ""

# Check prerequisites
for cmd in curl jq git wg ssh-keygen; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Installing missing prerequisite: $cmd"
        sudo apt-get update -qq && sudo apt-get install -y -qq \
            curl jq git wireguard-tools openssh-client 2>/dev/null
        break
    fi
done

SCRIPT_DIR=$(mktemp -d)
curl -sL "https://raw.githubusercontent.com/ecoPrimals/plasmidBin/main/enroll/gate-enroll.sh" \
    -o "$SCRIPT_DIR/gate-enroll.sh" 2>/dev/null \
    || curl -sL "http://157.230.3.183:7780/jsonrpc" \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"mesh.status\",\"params\":{},\"id\":1}" > /dev/null 2>&1

if [ ! -f "$SCRIPT_DIR/gate-enroll.sh" ]; then
    echo "Could not fetch gate-enroll.sh — using local copy if available"
    if [ -f "./gate-enroll.sh" ]; then
        cp ./gate-enroll.sh "$SCRIPT_DIR/"
    elif [ -f "$HOME/Development/ecoPrimals/infra/plasmidBin/enroll/gate-enroll.sh" ]; then
        cp "$HOME/Development/ecoPrimals/infra/plasmidBin/enroll/gate-enroll.sh" "$SCRIPT_DIR/"
    else
        echo "FATAL: gate-enroll.sh not found. Copy it to this machine first."
        exit 1
    fi
fi

chmod +x "$SCRIPT_DIR/gate-enroll.sh"
"$SCRIPT_DIR/gate-enroll.sh" \
    --hub "$HUB" \
    --gate "$GATE_NAME" \
    --token "$TOKEN" \
    --compose "$COMPOSE"

echo ""
echo "=== $GATE_NAME enrollment complete ==="
echo "Next: clone repos from Forgejo and validate."
