#!/usr/bin/env bash
# plasmidBin/deploy_gate.sh — Deploy primals to a remote gate via SSH
#
# Deploys primal binaries to a remote machine and starts a primal composition.
# Two modes:
#   push:  SCP local plasmidBin binaries to remote (default)
#   pull:  Remote machine fetches its own binaries from GitHub Releases
#
# Usage:
#   ./deploy_gate.sh user@host                        # Push Tower (beardog+songbird)
#   ./deploy_gate.sh user@host --composition compute  # Push Tower + toadstool
#   ./deploy_gate.sh user@host --composition full     # Push full NUCLEUS
#   ./deploy_gate.sh user@host --mode pull            # Remote fetches from GitHub
#   ./deploy_gate.sh user@host --family-seed ~/.config/biomeos/.family.seed
#   ./deploy_gate.sh user@host --dry-run              # Show plan, don't execute
#
# Prerequisites:
#   - SSH access to remote (key-based auth recommended)
#   - Remote is Linux (x86_64 or aarch64 — auto-detected)
#
# TCP ports are fallback defaults from ports.env. On the same machine,
# primals use Unix sockets with zero port configuration.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=ports.env
source "$SCRIPT_DIR/ports.env"

PRIMALS_DIR="$SCRIPT_DIR/primals"

REMOTE_PLASMID_DIR="/opt/plasmidBin"
REMOTE_RUNTIME_DIR="/tmp/biomeos"

DRY_RUN=false
MODE="push"
COMPOSITION="tower"
FAMILY_SEED=""
FAMILY_ID=""
NODE_ID="gate-$(date +%s | tail -c 5)"
GATE=""
DARK_FOREST=false
BEACON_SEED=""
LOCAL_VALIDATE=false
VALIDATE_TOPOLOGY=""
SYSTEMD=false
UDS_ONLY=false
REMOTE_INSTALL_DIR="/opt/membrane"

usage() {
    echo "Usage: $0 <user@host> [OPTIONS]"
    echo ""
    echo "Atomic compositions:"
    echo "  tower         BearDog + Songbird + SkunkBat (trust boundary)"
    echo "  node          Tower + ToadStool + barraCuda + coralReef (compute)"
    echo "  nest          Tower + NestGate + Provenance Trio (storage + lineage)"
    echo "  nucleus       Tower + Node + Nest (10 primals)"
    echo "  meta          biomeOS + Squirrel + petalTongue"
    echo "  full          NUCLEUS + Meta (13 primals)"
    echo "  fieldMouse    Tower + Nest (7 primals — depot/beacon/archive)"
    echo "  depot         Tower only (3 primals — minimal signal/rendezvous)"
    echo ""
    echo "Spring niche compositions (primals a spring needs):"
    echo "  niche-hotspring, niche-neuralspring, niche-wetspring,"
    echo "  niche-airspring, niche-groundspring, niche-healthspring,"
    echo "  niche-ludospring"
    echo ""
    echo "Legacy: compute, provenance, science"
    echo ""
    echo "Options:"
    echo "  --composition NAME   Primal composition to deploy"
    echo "  --mode MODE          push|pull|bootstrap (push=SCP, pull=remote fetch, bootstrap=print command)"
    echo "  --family-seed PATH   .family.seed file for enrollment"
    echo "  --family-id ID       Family ID (auto-generated if seed provided)"
    echo "  --node-id ID         Node identifier (default: gate-XXXXX)"
    echo "  --remote-dir DIR     Remote plasmidBin directory (default: /opt/plasmidBin)"
    echo "  --dark-forest        Enable Dark Forest beacon mode"
    echo "  --beacon-seed PATH   .beacon.seed file for BirdSong discovery"
    echo "  --systemd            Install systemd units (production mode, restart-on-failure)"
    echo "  --uds-only           UDS-only: no TCP port binding (VPS standard)"
    echo "  --install-dir DIR    Remote binary directory (default: /opt/membrane)"
    echo "  --local-validate     Run benchScale Docker validation before deploying"
    echo "  --topology NAME      benchScale topology for --local-validate (auto-detected)"
    echo "  --dry-run            Show what would happen, don't execute"
    echo "  --help               Show this help"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --composition)  COMPOSITION="$2"; shift 2 ;;
        --mode)         MODE="$2"; shift 2 ;;
        --family-seed)  FAMILY_SEED="$2"; shift 2 ;;
        --family-id)    FAMILY_ID="$2"; shift 2 ;;
        --node-id)      NODE_ID="$2"; shift 2 ;;
        --remote-dir)   REMOTE_PLASMID_DIR="$2"; shift 2 ;;
        --dark-forest)  DARK_FOREST=true; shift ;;
        --beacon-seed)  BEACON_SEED="$2"; shift 2 ;;
        --systemd)      SYSTEMD=true; shift ;;
        --uds-only)     UDS_ONLY=true; shift ;;
        --install-dir)  REMOTE_INSTALL_DIR="$2"; shift 2 ;;
        --local-validate) LOCAL_VALIDATE=true; shift ;;
        --topology)     VALIDATE_TOPOLOGY="$2"; shift 2 ;;
        --dry-run)      DRY_RUN=true; shift ;;
        --help)         usage; exit 0 ;;
        -*)             echo "Unknown option: $1"; usage; exit 1 ;;
        *)              GATE="$1"; shift ;;
    esac
done

if [[ -z "$GATE" ]]; then
    echo "ERROR: Specify remote gate as user@host"
    echo ""
    usage
    exit 1
fi

# Resolve composition to primal list
PRIMALS=$(primals_for_composition "$COMPOSITION")

# Remote bootstrap mode: print the command for the remote user to run
if [[ "$MODE" == "bootstrap" ]]; then
    echo "plasmidBin remote bootstrap — $(date -Iseconds)"
    echo ""
    echo "Have the remote user paste this command:"
    echo ""
    BOOTSTRAP_CMD="curl -sL https://raw.githubusercontent.com/ecoPrimals/plasmidBin/main/bootstrap_gate.sh | bash -s -- --family-id ${FAMILY_ID:-\$(echo $NODE_ID | md5sum | head -c 8)}"
    if $DARK_FOREST; then
        BOOTSTRAP_CMD+=" --dark-forest"
    fi
    if [[ -n "$BEACON_SEED" && -f "$BEACON_SEED" ]]; then
        B64=$(base64 -w0 "$BEACON_SEED")
        BOOTSTRAP_CMD+=" --beacon-seed $B64"
    fi
    echo "  $BOOTSTRAP_CMD"
    echo ""
    echo "Or download and run manually:"
    echo "  wget -qO bootstrap.sh https://raw.githubusercontent.com/ecoPrimals/plasmidBin/main/bootstrap_gate.sh"
    echo "  chmod +x bootstrap.sh"
    echo "  ./bootstrap.sh --family-id ${FAMILY_ID:-auto}"
    exit 0
fi

echo "plasmidBin deploy — $(date -Iseconds)"
echo "Gate:        $GATE"
echo "Composition: $COMPOSITION ($PRIMALS)"
echo "Mode:        $MODE"
echo "Node ID:     $NODE_ID"
echo "Remote dir:  $REMOTE_PLASMID_DIR"
$SYSTEMD && echo "Systemd:     enabled (production mode)"
$UDS_ONLY && echo "Transport:   UDS-only (no TCP)"
if [[ -n "$FAMILY_SEED" ]]; then
    echo "Family seed: $FAMILY_SEED"
fi
echo ""

# Verify local binaries exist (push mode)
if [[ "$MODE" == "push" ]]; then
    MISSING=0
    for p in $PRIMALS; do
        if [[ ! -f "$PRIMALS_DIR/$p" ]] && [[ ! -f "$PRIMALS_DIR/aarch64/$p" ]]; then
            echo "ERROR: Local binary missing for any arch: $p"
            MISSING=$((MISSING + 1))
        fi
    done
    if [[ $MISSING -gt 0 ]]; then
        echo ""
        echo "Run harvest.sh first, or use --mode pull for remote fetch."
        exit 1
    fi
fi

if $DRY_RUN; then
    echo "[dry-run] Would execute the following:"
    echo ""
fi

# ── Local Validation (optional) ─────────────────────────────────────────────
# Run benchScale Docker lab validation before deploying to a real gate.
# Catches composition failures, CLI mismatches, and wiring issues locally.

if $LOCAL_VALIDATE; then
    echo "=== Pre-deploy: Local Validation ==="

    PRIMALSPRING_ROOT="$SCRIPT_DIR/../../springs/primalSpring"
    VALIDATE_SCRIPT="$PRIMALSPRING_ROOT/scripts/validate_local_lab.sh"

    if [ ! -f "$VALIDATE_SCRIPT" ]; then
        echo "  ERROR: validate_local_lab.sh not found at $VALIDATE_SCRIPT"
        echo "  Ensure primalSpring is checked out alongside plasmidBin"
        exit 1
    fi

    if [ -z "$VALIDATE_TOPOLOGY" ]; then
        case "$COMPOSITION" in
            tower)    VALIDATE_TOPOLOGY="ecoprimals-tower-2node" ;;
            full)     VALIDATE_TOPOLOGY="ecoprimals-nucleus-3node" ;;
            *)        VALIDATE_TOPOLOGY="ecoprimals-tower-2node" ;;
        esac
    fi

    echo "  Topology: $VALIDATE_TOPOLOGY"
    echo "  Running validation..."
    echo ""

    if $DRY_RUN; then
        echo "  [dry-run] Would run: $VALIDATE_SCRIPT --topology $VALIDATE_TOPOLOGY --timeout 30"
    else
        if "$VALIDATE_SCRIPT" --topology "$VALIDATE_TOPOLOGY" --timeout 30; then
            echo ""
            echo "  Local validation PASSED. Proceeding with remote deploy."
            echo ""
        else
            echo ""
            echo "  Local validation FAILED. Fix issues before deploying to remote gate."
            echo "  Re-run with --dry-run to skip validation, or fix and retry."
            exit 1
        fi
    fi
fi

# Helper: run a command, or just print it in dry-run
run() {
    if $DRY_RUN; then
        echo "  $*"
    else
        "$@"
    fi
}

run_ssh() {
    if $DRY_RUN; then
        echo "  ssh $GATE \"$*\""
    else
        ssh "$GATE" "$@"
    fi
}

# ── Phase 1: Prepare remote directory ────────────────────────────────────────

echo "=== Phase 1: Prepare remote ==="

run_ssh "mkdir -p $REMOTE_PLASMID_DIR/primals $REMOTE_RUNTIME_DIR"

REMOTE_ARCH=""
if ! $DRY_RUN; then
    REMOTE_ARCH=$(ssh "$GATE" "uname -m" 2>/dev/null | tr -d '\r\n') || true
else
    echo "  [dry-run] would detect remote arch via: ssh $GATE uname -m"
    REMOTE_ARCH="x86_64"
fi
echo "  Remote arch: ${REMOTE_ARCH:-unknown}"

LOCAL_SRC="$PRIMALS_DIR"
if [[ "$REMOTE_ARCH" == "aarch64" ]]; then
    LOCAL_SRC="$PRIMALS_DIR/aarch64"
    echo "  Using aarch64 binaries from $LOCAL_SRC"
fi

# ── Phase 2: Deliver binaries ────────────────────────────────────────────────

echo "=== Phase 2: Deliver binaries ($MODE) ==="

if [[ "$MODE" == "push" ]]; then
    for p in $PRIMALS; do
        echo "  Pushing $p..."
        run scp -q "$LOCAL_SRC/$p" "$GATE:$REMOTE_PLASMID_DIR/primals/$p"
    done
    run_ssh "chmod +x $REMOTE_PLASMID_DIR/primals/*"

elif [[ "$MODE" == "pull" ]]; then
    echo "  Cloning/updating plasmidBin on remote..."
    run_ssh "
        if [ -d $REMOTE_PLASMID_DIR/.git ]; then
            cd $REMOTE_PLASMID_DIR && git pull --rebase 2>/dev/null || true
        else
            git clone https://github.com/ecoPrimals/plasmidBin.git $REMOTE_PLASMID_DIR 2>/dev/null || true
        fi
        cd $REMOTE_PLASMID_DIR && chmod +x fetch.sh 2>/dev/null
        if command -v b3sum >/dev/null 2>&1; then
            ./fetch.sh --all
        else
            echo 'NOTE: b3sum not installed — fetching without checksum verification'
            ./fetch.sh --all
        fi
    "
fi

# ── Phase 3: Deliver family seed (if provided) ──────────────────────────────

if [[ -n "$FAMILY_SEED" || -n "$BEACON_SEED" ]]; then
    echo "=== Phase 3: Family enrollment ==="
    if [[ -n "$FAMILY_SEED" && -f "$FAMILY_SEED" ]]; then
        run scp -q "$FAMILY_SEED" "$GATE:$REMOTE_PLASMID_DIR/.family.seed"
        run_ssh "chmod 600 $REMOTE_PLASMID_DIR/.family.seed"
        echo "  Family seed delivered."
    elif [[ -n "$FAMILY_SEED" ]]; then
        echo "  WARNING: Family seed not found: $FAMILY_SEED"
    fi
    if [[ -n "$BEACON_SEED" && -f "$BEACON_SEED" ]]; then
        run scp -q "$BEACON_SEED" "$GATE:$REMOTE_PLASMID_DIR/.beacon.seed"
        run_ssh "chmod 600 $REMOTE_PLASMID_DIR/.beacon.seed"
        echo "  Beacon seed (mitobeacon) delivered."
    elif [[ -n "$BEACON_SEED" ]]; then
        echo "  WARNING: Beacon seed not found: $BEACON_SEED"
    fi
fi

# ── Systemd unit generator ────────────────────────────────────────────────
# Generates a systemd service unit for a single primal. Used by --systemd mode.

generate_systemd_unit() {
    local primal="$1"
    local install_dir="$2"
    local description port socket_flag

    case "$primal" in
        beardog)     description="BearDog — crypto spine" ;;
        songbird)    description="Songbird — discovery + federation" ;;
        skunkbat)    description="SkunkBat — defense + audit" ;;
        toadstool)   description="ToadStool — compute dispatch" ;;
        barracuda)   description="barraCuda — pure math" ;;
        coralreef)   description="coralReef — shader compilation" ;;
        nestgate)    description="NestGate — content-addressed storage" ;;
        rhizocrypt)  description="rhizoCrypt — ephemeral DAG sessions" ;;
        loamspine)   description="loamSpine — permanent ledger" ;;
        sweetgrass)  description="sweetGrass — attribution braids" ;;
        biomeos)     description="biomeOS — Neural API orchestrator" ;;
        squirrel)    description="Squirrel — AI coordination" ;;
        petaltongue) description="petalTongue — visualization" ;;
        *)           description="$primal" ;;
    esac

    port=$(port_for_primal "$primal")

    local exec_start
    if $UDS_ONLY; then
        socket_flag="--socket /run/membrane/${primal}.sock"
        case "$primal" in
            beardog)     exec_start="$install_dir/$primal server $socket_flag" ;;
            songbird)    exec_start="$install_dir/$primal server $socket_flag" ;;
            skunkbat)    exec_start="$install_dir/$primal server $socket_flag" ;;
            nestgate)    exec_start="$install_dir/$primal service start $socket_flag" ;;
            biomeos)     exec_start="$install_dir/$primal api $socket_flag" ;;
            squirrel)    exec_start="$install_dir/$primal server $socket_flag" ;;
            petaltongue) exec_start="$install_dir/$primal server $socket_flag" ;;
            rhizocrypt|loamspine|sweetgrass)
                         exec_start="$install_dir/$primal serve $socket_flag" ;;
            *)           exec_start="$install_dir/$primal server $socket_flag" ;;
        esac
    else
        socket_flag="--socket /run/membrane/${primal}.sock"
        case "$primal" in
            beardog)     exec_start="$install_dir/$primal server $socket_flag --listen 0.0.0.0:$port" ;;
            songbird)    exec_start="$install_dir/$primal server --port $port $socket_flag" ;;
            skunkbat)    exec_start="$install_dir/$primal server --port $port $socket_flag" ;;
            nestgate)    exec_start="$install_dir/$primal service start --port $port --bind 0.0.0.0 $socket_flag" ;;
            biomeos)     exec_start="$install_dir/$primal api --port $port $socket_flag" ;;
            squirrel)    exec_start="$install_dir/$primal server --port $port --bind 0.0.0.0 $socket_flag" ;;
            petaltongue) exec_start="$install_dir/$primal web --bind 0.0.0.0:$port" ;;
            rhizocrypt)  exec_start="$install_dir/$primal server --port $port --host 0.0.0.0 $socket_flag" ;;
            loamspine)   exec_start="$install_dir/$primal server --port $port --bind-address 0.0.0.0 $socket_flag" ;;
            sweetgrass)  exec_start="$install_dir/$primal server --port 0.0.0.0:$port $socket_flag" ;;
            *)           exec_start="$install_dir/$primal server --port $port $socket_flag" ;;
        esac
    fi

    local after="network.target"
    local wants=""
    case "$primal" in
        songbird|skunkbat) after="network.target ${primal%%_*}-membrane.service"; after="network.target beardog-membrane.service"; wants="beardog-membrane.service" ;;
        biomeos) after="network.target beardog-membrane.service songbird-membrane.service"; wants="beardog-membrane.service songbird-membrane.service" ;;
        squirrel|petaltongue) after="network.target biomeos-membrane.service" ;;
    esac

    cat <<UNIT
[Unit]
Description=$description (membrane)
After=$after
${wants:+Wants=$wants}

[Service]
Type=simple
ExecStart=$exec_start
Restart=on-failure
RestartSec=5
EnvironmentFile=-$install_dir/tower.env

[Install]
WantedBy=multi-user.target
UNIT
}

# ── Phase 4: Start primal composition ────────────────────────────────────────

if $SYSTEMD; then
    echo "=== Phase 4: Install systemd units ==="

    RESOLVED_FAMILY_ID="${FAMILY_ID:-$(echo $NODE_ID | md5sum | head -c 8)}"

    if $DRY_RUN; then
        echo "  [dry-run] Would generate tower.env at $REMOTE_INSTALL_DIR/tower.env"
        for p in $PRIMALS; do
            echo "  [dry-run] Would install ${p}-membrane.service"
        done
        echo "  [dry-run] Would enable and start all services"
    else
        echo "  Creating tower.env..."
        SEED_VALUE=""
        if [[ -n "$FAMILY_SEED" && -f "$FAMILY_SEED" ]]; then
            SEED_VALUE=$(cat "$FAMILY_SEED")
        elif [[ -n "$BEACON_SEED" && -f "$BEACON_SEED" ]]; then
            SEED_VALUE=$(cat "$BEACON_SEED")
        fi

        run_ssh "mkdir -p $REMOTE_INSTALL_DIR /run/membrane"

        if [[ -n "$SEED_VALUE" ]]; then
            run_ssh "cat > $REMOTE_INSTALL_DIR/tower.env << 'TENV'
MEMBRANE_ROLE=$COMPOSITION
MEMBRANE_GATE_ID=$NODE_ID
FAMILY_ID=$RESOLVED_FAMILY_ID
BEARDOG_FAMILY_SEED=$SEED_VALUE
FAMILY_SEED=$SEED_VALUE
NODE_ID=$NODE_ID
BEARDOG_NODE_ID=$NODE_ID
SONGBIRD_NODE_ID=$NODE_ID
TENV
chmod 600 $REMOTE_INSTALL_DIR/tower.env"
        else
            run_ssh "test -f $REMOTE_INSTALL_DIR/tower.env || cat > $REMOTE_INSTALL_DIR/tower.env << TENV
MEMBRANE_ROLE=$COMPOSITION
MEMBRANE_GATE_ID=$NODE_ID
FAMILY_ID=$RESOLVED_FAMILY_ID
BEARDOG_FAMILY_SEED=\$(head -c 32 /dev/urandom | xxd -p -c 64)
NODE_ID=$NODE_ID
BEARDOG_NODE_ID=$NODE_ID
SONGBIRD_NODE_ID=$NODE_ID
TENV
chmod 600 $REMOTE_INSTALL_DIR/tower.env"
        fi

        UNIT_NAMES=""
        for p in $PRIMALS; do
            UNIT_NAME="${p}-membrane.service"
            UNIT_NAMES="$UNIT_NAMES $UNIT_NAME"
            echo "  Installing $UNIT_NAME..."
            UNIT_CONTENT=$(generate_systemd_unit "$p" "$REMOTE_INSTALL_DIR")
            echo "$UNIT_CONTENT" | ssh "$GATE" "cat > /etc/systemd/system/$UNIT_NAME"
        done

        echo "  Enabling services..."
        run_ssh "systemctl daemon-reload && systemctl enable $UNIT_NAMES"

        echo "  Starting services..."
        for p in $PRIMALS; do
            UNIT_NAME="${p}-membrane.service"
            run_ssh "systemctl restart $UNIT_NAME" 2>/dev/null || echo "  WARNING: $UNIT_NAME failed to start"
            sleep 2
        done
    fi

    echo ""
    echo "=== Phase 5: Service verification ==="

    if ! $DRY_RUN; then
        ALL_OK=true
        for p in $PRIMALS; do
            STATE=$(ssh "$GATE" "systemctl is-active ${p}-membrane 2>/dev/null || echo inactive")
            if [[ "$STATE" == "active" ]]; then
                echo "  ${p}-membrane: ACTIVE"
            else
                echo "  ${p}-membrane: $STATE"
                ALL_OK=false
            fi
        done

        echo ""
        if $ALL_OK; then
            echo "All services active."
        else
            echo "Some services not active. Check: ssh $GATE 'journalctl -u <service> --no-pager -n 20'"
        fi
    else
        for p in $PRIMALS; do
            echo "  [dry-run] Would check ${p}-membrane.service"
        done
    fi

    echo ""
    echo "=== Deploy complete (systemd) ==="
    echo "Manage:   ssh $GATE 'systemctl status ${PRIMALS%% *}-membrane'"
    echo "Logs:     ssh $GATE 'journalctl -u ${PRIMALS%% *}-membrane --no-pager -n 50'"
    echo "Validate: ./validate_gate.sh $(echo $GATE | cut -d@ -f2)"

else
    # ── Original foreground mode (nohup) ─────────────────────────────────────
    echo "=== Phase 4: Start primals ==="

    STARTUP_SCRIPT="#!/bin/bash
set -euo pipefail
export ECOPRIMALS_PLASMID_BIN=$REMOTE_PLASMID_DIR
export XDG_RUNTIME_DIR=$REMOTE_RUNTIME_DIR
mkdir -p \$XDG_RUNTIME_DIR/biomeos

export FAMILY_ID=\"${FAMILY_ID:-$(echo $NODE_ID | md5sum | head -c 8)}\"
export NODE_ID=\"$NODE_ID\"
"

    if $DARK_FOREST; then
        STARTUP_SCRIPT+="
export SONGBIRD_DARK_FOREST=true
export SONGBIRD_AUTO_DISCOVERY=true
"
    fi

    STARTUP_SCRIPT+="
echo \"Starting primal composition: $COMPOSITION\"
echo \"Family: \$FAMILY_ID  Node: \$NODE_ID  Dark Forest: $DARK_FOREST\"
echo \"\"

for p in $PRIMALS; do
    pkill -f \"\$ECOPRIMALS_PLASMID_BIN/primals/\$p\" 2>/dev/null || true
done
sleep 1
"

    for p in $PRIMALS; do
        PORT=$(port_for_primal "$p")
        case "$p" in
            beardog)
                STARTUP_SCRIPT+="
echo \"Starting beardog (UDS + TCP $PORT)...\"
nohup \$ECOPRIMALS_PLASMID_BIN/primals/beardog server \\
    --socket \$XDG_RUNTIME_DIR/biomeos/beardog-\$FAMILY_ID.sock \\
    --family-id \$FAMILY_ID \\
    --listen 0.0.0.0:$PORT \\
    > /tmp/beardog.log 2>&1 &
sleep 2
"
                ;;
            songbird)
                STARTUP_SCRIPT+="
echo \"Starting songbird (HTTP $PORT + UDS)...\"
export BEARDOG_SOCKET=\$XDG_RUNTIME_DIR/biomeos/beardog-\$FAMILY_ID.sock
export SONGBIRD_SECURITY_PROVIDER=beardog
nohup \$ECOPRIMALS_PLASMID_BIN/primals/songbird server \\
    --port $PORT \\
    --socket \$XDG_RUNTIME_DIR/biomeos/songbird-\$FAMILY_ID.sock \\
    > /tmp/songbird.log 2>&1 &
sleep 2
"
                ;;
            *)
                STARTUP_SCRIPT+="
echo \"Starting $p...\"
nohup \$ECOPRIMALS_PLASMID_BIN/primals/$p server \\
    --port $PORT \\
    --socket \$XDG_RUNTIME_DIR/biomeos/${p}-\$FAMILY_ID.sock \\
    > /tmp/${p}.log 2>&1 &
sleep 2
"
                ;;
        esac
    done

    STARTUP_SCRIPT+="
echo \"\"
echo \"=== Gate Ready ===\"
echo \"Composition: $COMPOSITION\"
"

    echo "  Deploying startup script..."
    if $DRY_RUN; then
        echo "  [dry-run] Startup script would be:"
        echo "$STARTUP_SCRIPT" | head -20
        echo "  ..."
    else
        echo "$STARTUP_SCRIPT" | ssh "$GATE" "cat > $REMOTE_PLASMID_DIR/start_gate.sh && chmod +x $REMOTE_PLASMID_DIR/start_gate.sh"
        echo "  Running startup..."
        ssh "$GATE" "bash $REMOTE_PLASMID_DIR/start_gate.sh"
    fi

    # ── Phase 5: Quick TCP probe ──────────────────────────────────────────
    REMOTE_HOST=$(echo "$GATE" | cut -d@ -f2)

    echo ""
    echo "=== Phase 5: Quick probe ==="

    if ! $DRY_RUN; then
        sleep 2
        ALL_OK=true
        for p in $PRIMALS; do
            PORT=$(port_for_primal "$p")
            if timeout 3 bash -c "echo '' > /dev/tcp/$REMOTE_HOST/$PORT" 2>/dev/null; then
                echo "  $p ($REMOTE_HOST:$PORT): REACHABLE"
            else
                echo "  $p ($REMOTE_HOST:$PORT): NOT REACHABLE"
                ALL_OK=false
            fi
        done
    else
        for p in $PRIMALS; do
            PORT=$(port_for_primal "$p")
            echo "  [dry-run] Would probe $REMOTE_HOST:$PORT ($p)"
        done
    fi

    echo ""
    echo "=== Deploy complete ==="
    echo "Remote start script: $GATE:$REMOTE_PLASMID_DIR/start_gate.sh"
    echo "Remote logs:         ssh $GATE 'tail /tmp/*.log'"
    echo "Validate:            ./validate_gate.sh $(echo $GATE | cut -d@ -f2)"
    echo "Stop:                ./stop_gate.sh $GATE"
fi
