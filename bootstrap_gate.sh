#!/usr/bin/env bash
# plasmidBin/bootstrap_gate.sh — One-command primal gate bootstrap
#
# Self-contained script for deploying primals to a fresh Linux machine.
# Designed for the "gamer friend" pattern: paste one command, get a running gate.
#
# Usage (on the remote machine):
#   curl -sL https://raw.githubusercontent.com/ecoPrimals/plasmidBin/main/bootstrap_gate.sh | \
#     bash -s -- --family-id cf7e8729
#
#   # Or download and run:
#   wget -qO bootstrap.sh https://raw.githubusercontent.com/ecoPrimals/plasmidBin/main/bootstrap_gate.sh
#   chmod +x bootstrap.sh
#   ./bootstrap.sh --family-id cf7e8729 --beacon-seed <base64-encoded-seed>
#
# What it does:
#   1. Clones plasmidBin (or updates if already present)
#   2. Fetches x86_64 musl-static binaries from GitHub Releases
#   3. Starts Tower composition (beardog + songbird) on standard ports
#   4. Prints public IP and validation instructions
#
# Standard ports:
#   beardog=9100 songbird=9200 nestgate=9300 toadstool=9400 squirrel=9500

set -euo pipefail

INSTALL_DIR="${PLASMIDBIN_DIR:-/opt/plasmidBin}"
RUNTIME_DIR="/tmp/biomeos"
REPO_URL="https://github.com/ecoPrimals/plasmidBin.git"

COMPOSITION="tower"
FAMILY_ID=""
BEACON_SEED_B64=""
NODE_ID=""
DARK_FOREST=false
SKIP_FETCH=false
SKIP_FIREWALL=false
DRY_RUN=false

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --family-id ID       Family ID for covalent bonding (REQUIRED)"
    echo "  --beacon-seed B64    Base64-encoded .beacon.seed (for Dark Forest)"
    echo "  --node-id ID         Node name (default: hostname-gate)"
    echo "  --composition NAME   tower|node|nest|nucleus|full (default: tower)"
    echo "  --dark-forest        Enable Dark Forest beacon mode"
    echo "  --install-dir DIR    Install directory (default: /opt/plasmidBin)"
    echo "  --skip-fetch         Don't fetch binaries (use existing)"
    echo "  --skip-firewall      Don't print firewall hints"
    echo "  --dry-run            Show plan, don't execute"
    echo "  --help               Show this help"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --family-id)      FAMILY_ID="$2"; shift 2 ;;
        --beacon-seed)    BEACON_SEED_B64="$2"; shift 2 ;;
        --node-id)        NODE_ID="$2"; shift 2 ;;
        --composition)    COMPOSITION="$2"; shift 2 ;;
        --dark-forest)    DARK_FOREST=true; shift ;;
        --install-dir)    INSTALL_DIR="$2"; shift 2 ;;
        --skip-fetch)     SKIP_FETCH=true; shift ;;
        --skip-firewall)  SKIP_FIREWALL=true; shift ;;
        --dry-run)        DRY_RUN=true; shift ;;
        --help)           usage; exit 0 ;;
        -*)               echo "Unknown option: $1"; usage; exit 1 ;;
        *)                echo "Unknown argument: $1"; usage; exit 1 ;;
    esac
done

if [[ -z "$FAMILY_ID" ]]; then
    echo "ERROR: --family-id is required for covalent bonding."
    echo ""
    echo "Get this from your family coordinator:"
    echo "  $0 --family-id <8-char-hex>"
    exit 1
fi

if [[ -z "$NODE_ID" ]]; then
    NODE_ID="$(hostname -s 2>/dev/null || echo 'gate')-gate"
fi

# Source shared definitions (ports are TCP fallback defaults, not requirements)
# On fresh clone this file may not exist yet — define inline fallbacks
if [[ -f "$INSTALL_DIR/ports.env" ]]; then
    # shellcheck source=ports.env
    source "$INSTALL_DIR/ports.env"
else
    BEARDOG_PORT="${BEARDOG_PORT:-9100}"
    SONGBIRD_PORT="${SONGBIRD_PORT:-9200}"
    NESTGATE_PORT="${NESTGATE_PORT:-9300}"
    TOADSTOOL_PORT="${TOADSTOOL_PORT:-9400}"
    SQUIRREL_PORT="${SQUIRREL_PORT:-9500}"
    PETALTONGUE_PORT="${PETALTONGUE_PORT:-9600}"
    RHIZOCRYPT_PORT="${RHIZOCRYPT_PORT:-9700}"
    LOAMSPINE_PORT="${LOAMSPINE_PORT:-9710}"
    SWEETGRASS_PORT="${SWEETGRASS_PORT:-9720}"
    CORALREEF_PORT="${CORALREEF_PORT:-9730}"
    BARRACUDA_PORT="${BARRACUDA_PORT:-9740}"
    SKUNKBAT_PORT="${SKUNKBAT_PORT:-9750}"
    BIOMEOS_PORT="${BIOMEOS_PORT:-9800}"
    primals_for_composition() {
        case "$1" in
            tower)   echo "beardog songbird skunkbat" ;;
            node)    echo "beardog songbird skunkbat toadstool barracuda coralreef" ;;
            nest)    echo "beardog songbird skunkbat nestgate rhizocrypt loamspine sweetgrass" ;;
            nucleus) echo "beardog songbird skunkbat toadstool barracuda coralreef nestgate rhizocrypt loamspine sweetgrass" ;;
            full)    echo "beardog songbird skunkbat toadstool barracuda coralreef nestgate rhizocrypt loamspine sweetgrass biomeos squirrel petaltongue" ;;
            *)       echo "ERROR: Unknown composition: $1" >&2; return 1 ;;
        esac
    }
    port_for_primal() {
        case "$1" in
            beardog)      echo "$BEARDOG_PORT" ;;
            songbird)     echo "$SONGBIRD_PORT" ;;
            nestgate)     echo "$NESTGATE_PORT" ;;
            toadstool)    echo "$TOADSTOOL_PORT" ;;
            squirrel)     echo "$SQUIRREL_PORT" ;;
            petaltongue)  echo "$PETALTONGUE_PORT" ;;
            rhizocrypt)   echo "$RHIZOCRYPT_PORT" ;;
            loamspine)    echo "$LOAMSPINE_PORT" ;;
            sweetgrass)   echo "$SWEETGRASS_PORT" ;;
            coralreef)    echo "$CORALREEF_PORT" ;;
            barracuda)    echo "$BARRACUDA_PORT" ;;
            skunkbat)     echo "$SKUNKBAT_PORT" ;;
            biomeos)      echo "$BIOMEOS_PORT" ;;
            *)            echo "0" ;;
        esac
    }
fi

PRIMALS=$(primals_for_composition "$COMPOSITION")

echo ""
echo "=============================================="
echo "  plasmidBin Gate Bootstrap"
echo "=============================================="
echo ""
echo "Family ID:   $FAMILY_ID"
echo "Node ID:     $NODE_ID"
echo "Composition: $COMPOSITION ($PRIMALS)"
echo "Install dir: $INSTALL_DIR"
echo "Dark Forest: $DARK_FOREST"
echo ""

# ── Phase 1: Install plasmidBin ─────────────────────────────────────────────

echo "=== Phase 1: Install plasmidBin ==="

if [[ -d "$INSTALL_DIR/.git" ]]; then
    echo "  Updating existing installation..."
    if ! $DRY_RUN; then
        cd "$INSTALL_DIR" && git pull --rebase origin main 2>/dev/null || true
    fi
elif [[ -d "$INSTALL_DIR" ]]; then
    echo "  Directory exists (not a git repo). Using as-is."
else
    echo "  Cloning plasmidBin..."
    if ! $DRY_RUN; then
        sudo mkdir -p "$INSTALL_DIR" 2>/dev/null || mkdir -p "$INSTALL_DIR"
        sudo chown "$(id -u):$(id -g)" "$INSTALL_DIR" 2>/dev/null || true
        git clone "$REPO_URL" "$INSTALL_DIR"
    fi
fi

if ! $DRY_RUN; then
    cd "$INSTALL_DIR"
fi
echo ""

# ── Phase 2: Fetch binaries ─────────────────────────────────────────────────

if ! $SKIP_FETCH; then
    echo "=== Phase 2: Fetch binaries ==="

    if [[ -x "$INSTALL_DIR/fetch.sh" ]]; then
        echo "  Running fetch.sh --all ..."
        if ! $DRY_RUN; then
            chmod +x "$INSTALL_DIR/fetch.sh"
            "$INSTALL_DIR/fetch.sh" --all || {
                echo "  WARNING: fetch.sh failed. Checking if binaries exist locally..."
            }
        fi
    else
        echo "  fetch.sh not found — checking for local binaries..."
    fi

    MISSING=0
    for p in $PRIMALS; do
        if [[ -f "$INSTALL_DIR/primals/$p" && -x "$INSTALL_DIR/primals/$p" ]]; then
            echo "  OK: $p ($(du -h "$INSTALL_DIR/primals/$p" | cut -f1))"
        else
            echo "  MISSING: $p"
            MISSING=$((MISSING + 1))
        fi
    done

    if [[ $MISSING -gt 0 ]]; then
        echo ""
        echo "ERROR: $MISSING binaries missing. Fetch failed."
        echo "  Ensure GitHub Releases have the latest binaries, or"
        echo "  have your family coordinator push binaries via deploy_gate.sh"
        exit 1
    fi
    echo ""
fi

# ── Phase 3: Decode beacon seed ─────────────────────────────────────────────

if [[ -n "$BEACON_SEED_B64" ]]; then
    echo "=== Phase 3: Decode beacon seed ==="
    if ! $DRY_RUN; then
        echo "$BEACON_SEED_B64" | base64 -d > "$INSTALL_DIR/.beacon.seed"
        chmod 600 "$INSTALL_DIR/.beacon.seed"
        echo "  Beacon seed decoded and stored."
    else
        echo "  [dry-run] Would decode beacon seed"
    fi
    echo ""
fi

# ── Phase 4: Create runtime directory ────────────────────────────────────────

echo "=== Phase 4: Setup runtime ==="
if ! $DRY_RUN; then
    mkdir -p "$RUNTIME_DIR"
fi
echo "  Runtime: $RUNTIME_DIR"
echo ""

# ── Phase 5: Start primals ──────────────────────────────────────────────────

echo "=== Phase 5: Start primals ==="

# Kill any existing
for p in $PRIMALS; do
    pkill -f "$INSTALL_DIR/primals/$p" 2>/dev/null || true
done
sleep 1

export FAMILY_ID="$FAMILY_ID"
export NODE_ID="$NODE_ID"
export ECOPRIMALS_PLASMID_BIN="$INSTALL_DIR"
export XDG_RUNTIME_DIR="$RUNTIME_DIR"

if $DARK_FOREST; then
    export SONGBIRD_DARK_FOREST=true
    export SONGBIRD_AUTO_DISCOVERY=true
fi

mkdir -p "$RUNTIME_DIR/biomeos"

# If nucleus_launcher.sh is available and composition is complex, delegate to it
if [[ -x "$INSTALL_DIR/nucleus_launcher.sh" ]] && [[ "$COMPOSITION" != "tower" ]]; then
    echo "  Delegating to nucleus_launcher.sh for $COMPOSITION..."
    if ! $DRY_RUN; then
        DF_FLAG=""
        $DARK_FOREST && DF_FLAG="--dark-forest"
        "$INSTALL_DIR/nucleus_launcher.sh" \
            --family-id "$FAMILY_ID" \
            --node-id "$NODE_ID" \
            --composition "$COMPOSITION" \
            $DF_FLAG
    fi
else
    # Inline startup for Tower composition or when launcher is unavailable
    for p in $PRIMALS; do
        PORT=$(port_for_primal "$p")
        SOCKET="$RUNTIME_DIR/biomeos/${p}-${FAMILY_ID}.sock"

        if [[ -x "$INSTALL_DIR/start_primal.sh" ]]; then
            echo "  Starting $p (TCP $PORT)..."
            if ! $DRY_RUN; then
                DF_FLAG=""
                $DARK_FOREST && DF_FLAG="--dark-forest"
                "$INSTALL_DIR/start_primal.sh" "$p" \
                    --tcp-port "$PORT" \
                    --socket "$SOCKET" \
                    --family-id "$FAMILY_ID" \
                    --log-file "/tmp/${p}.log" \
                    $DF_FLAG || true
            fi
        else
            # Fallback: direct startup for Tower primals
            case "$p" in
                beardog)
                    echo "  Starting beardog (UDS + TCP $PORT)..."
                    if ! $DRY_RUN; then
                        nohup "$INSTALL_DIR/primals/beardog" server \
                            --socket "$SOCKET" \
                            --family-id "$FAMILY_ID" \
                            --listen "0.0.0.0:$PORT" \
                            > /tmp/beardog.log 2>&1 &
                        echo "    PID: $!"
                        sleep 2
                    fi
                    ;;
                songbird)
                    echo "  Starting songbird (HTTP $PORT + UDS)..."
                    if ! $DRY_RUN; then
                        export BEARDOG_SOCKET="$RUNTIME_DIR/biomeos/beardog-$FAMILY_ID.sock"
                        export BEARDOG_MODE=direct
                        export SONGBIRD_SECURITY_PROVIDER=beardog
                        nohup "$INSTALL_DIR/primals/songbird" server \
                            --port "$PORT" \
                            --socket "$SOCKET" \
                            > /tmp/songbird.log 2>&1 &
                        echo "    PID: $!"
                        sleep 2
                    fi
                    ;;
                *)
                    echo "  WARNING: No inline handler for $p — use nucleus_launcher.sh"
                    ;;
            esac
        fi
    done
fi

echo ""

# ── Phase 6: Verify ─────────────────────────────────────────────────────────

echo "=== Phase 6: Verify ==="

ALL_OK=true
for p in $PRIMALS; do
    PORT=$(port_for_primal "$p")
    if ! $DRY_RUN; then
        pid=$(pgrep -f "$INSTALL_DIR/primals/$p" 2>/dev/null | head -1) || true
        if [[ -n "$pid" ]]; then
            echo "  $p: PID $pid, TCP $PORT"
        else
            echo "  $p: NOT RUNNING (check /tmp/$p.log)"
            ALL_OK=false
        fi
    else
        echo "  [dry-run] Would verify $p on port $PORT"
    fi
done

echo ""

# ── Phase 7: Network info + firewall hints ───────────────────────────────────

echo "=== Phase 7: Network info ==="

if ! $DRY_RUN; then
    PUBLIC_IP=$(curl -sf --max-time 5 ifconfig.me 2>/dev/null) || PUBLIC_IP="(could not determine)"
    LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}') || LOCAL_IP="(unknown)"
else
    PUBLIC_IP="(dry-run)"
    LOCAL_IP="(dry-run)"
fi

echo "  Public IP:  $PUBLIC_IP"
echo "  Local IP:   $LOCAL_IP"
echo ""
echo "  TCP endpoints:"
for p in $PRIMALS; do
    PORT=$(port_for_primal "$p")
    echo "    $p: tcp://$LOCAL_IP:$PORT (LAN) / tcp://$PUBLIC_IP:$PORT (WAN)"
done

if ! $SKIP_FIREWALL; then
    echo ""
    echo "  Firewall — open these ports for remote access:"
    echo "  ┌──────────────────────────────────────────────────────┐"
    for p in $PRIMALS; do
        PORT=$(port_for_primal "$p")
        printf "  │  sudo ufw allow %s/tcp  # %-24s │\n" "$PORT" "$p"
    done
    echo "  └──────────────────────────────────────────────────────┘"
    echo ""
    echo "  Router port forwarding (if behind NAT):"
    for p in $PRIMALS; do
        PORT=$(port_for_primal "$p")
        echo "    Forward external $PORT -> $LOCAL_IP:$PORT (TCP)"
    done
fi

echo ""
echo "=============================================="
echo "  Gate bootstrap complete!"
echo "=============================================="
echo ""
echo "Tell your family coordinator:"
echo "  Public IP:  $PUBLIC_IP"
echo "  Family ID:  $FAMILY_ID"
echo "  Node ID:    $NODE_ID"
echo ""
echo "They can validate from their machine:"
echo "  ./validate_gate.sh $PUBLIC_IP"
echo ""
echo "To stop primals:"
echo "  pkill -f '$INSTALL_DIR/primals/'"
echo ""
echo "Logs: /tmp/{beardog,songbird,nestgate,toadstool,squirrel}.log"
