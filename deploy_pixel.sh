#!/usr/bin/env bash
# plasmidBin/deploy_pixel.sh — Deploy primals to Pixel/GrapheneOS via ADB
#
# Pushes aarch64 musl-static binaries to device, generates startup script,
# sets up ADB port forwarding, and starts primals with abstract sockets
# (SELinux-safe) and TCP listeners.
#
# Usage:
#   ./deploy_pixel.sh                           # Deploy Tower (beardog+songbird)
#   ./deploy_pixel.sh --composition compute     # Tower + toadstool
#   ./deploy_pixel.sh --dark-forest             # Enable Dark Forest beacons
#   ./deploy_pixel.sh --beacon-seed ~/.config/biomeos/.beacon.seed
#   ./deploy_pixel.sh --dry-run                 # Show plan, don't execute
#   ./deploy_pixel.sh --stop                    # Stop running primals on device
#
# Prerequisites:
#   - ADB connected to device (USB debugging enabled)
#   - aarch64 musl binaries in plasmidBin/primals/aarch64/
#     (build via: build_ecosystem_genomeBin.sh --aarch64 && harvest.sh --arch aarch64)
#
# Standard ports (from primalSpring tolerances):
#   beardog=9100 songbird=9200 squirrel=9300 toadstool=9400 nestgate=9500

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=ports.env
source "$SCRIPT_DIR/ports.env"

AARCH64_DIR="$SCRIPT_DIR/primals/aarch64-unknown-linux-musl"
# Try aarch64-linux-android (Pixel/GrapheneOS NDK target)
if [[ ! -d "$AARCH64_DIR" ]] || [[ -z "$(ls -A "$AARCH64_DIR" 2>/dev/null)" ]]; then
    AARCH64_DIR="$SCRIPT_DIR/primals/aarch64-linux-android"
fi
# Fall back to legacy layout
if [[ ! -d "$AARCH64_DIR" ]] || [[ -z "$(ls -A "$AARCH64_DIR" 2>/dev/null)" ]]; then
    AARCH64_DIR="$SCRIPT_DIR/primals/aarch64"
fi

REMOTE_DIR="/data/local/tmp/plasmidBin"
REMOTE_PRIMALS="$REMOTE_DIR/primals"
REMOTE_RUNTIME="/data/local/tmp/biomeos"

DRY_RUN=false
COMPOSITION="tower"
DARK_FOREST=false
BEACON_SEED=""
FAMILY_ID=""
NODE_ID="pixel"
DO_STOP=false
SKIP_FORWARD=false
LOCAL_PORT_OFFSET=0

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Compositions:"
    echo "  tower    BearDog + Songbird (default — crypto + network)"
    echo "  compute  Tower + ToadStool (mobile compute sharing)"
    echo "  full     All core primals"
    echo ""
    echo "Options:"
    echo "  --composition NAME   Primal composition (tower|compute|full)"
    echo "  --dark-forest        Enable Dark Forest beacon mode"
    echo "  --beacon-seed PATH   .beacon.seed file for BirdSong discovery"
    echo "  --family-id ID       Family ID (auto-generated from beacon seed if not set)"
    echo "  --node-id ID         Node identifier (default: pixel)"
    echo "  --no-forward         Skip ADB port forwarding"
    echo "  --local-port-offset N  Offset local ADB forward ports (e.g., 10000 -> 19100)"
    echo "  --stop               Stop primals on device and exit"
    echo "  --dry-run            Show plan, don't execute"
    echo "  --help               Show this help"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --composition)  COMPOSITION="$2"; shift 2 ;;
        --dark-forest)  DARK_FOREST=true; shift ;;
        --beacon-seed)  BEACON_SEED="$2"; shift 2 ;;
        --family-id)    FAMILY_ID="$2"; shift 2 ;;
        --node-id)      NODE_ID="$2"; shift 2 ;;
        --no-forward)   SKIP_FORWARD=true; shift ;;
        --local-port-offset) LOCAL_PORT_OFFSET="$2"; shift 2 ;;
        --stop)         DO_STOP=true; shift ;;
        --dry-run)      DRY_RUN=true; shift ;;
        --help)         usage; exit 0 ;;
        -*)             echo "Unknown option: $1"; usage; exit 1 ;;
        *)              echo "Unknown argument: $1"; usage; exit 1 ;;
    esac
done

# ── Helpers ──────────────────────────────────────────────────────────────────

run() {
    if $DRY_RUN; then
        echo "  [dry-run] $*"
    else
        "$@"
    fi
}

adb_sh() {
    if $DRY_RUN; then
        echo "  [dry-run] adb shell \"$*\""
    else
        adb shell "$@"
    fi
}

# ── Stop mode ────────────────────────────────────────────────────────────────

if $DO_STOP; then
    echo "Stopping primals on device..."
    adb_sh "pkill -f '$REMOTE_PRIMALS/' 2>/dev/null || true"
    sleep 1
    adb_sh "pkill -9 -f '$REMOTE_PRIMALS/' 2>/dev/null || true"
    echo "Removing ADB port forwards..."
    for p in $ALL_PRIMALS; do
        port=$(port_for_primal "$p")
        [[ "$port" == "0" ]] && continue
        adb forward --remove tcp:$port 2>/dev/null || true
    done
    echo "Done."
    exit 0
fi

# ── Verify ADB connection ───────────────────────────────────────────────────

if ! $DRY_RUN; then
    if ! adb get-state >/dev/null 2>&1; then
        echo "ERROR: No ADB device connected."
        echo "  Connect Pixel via USB and enable USB debugging."
        exit 1
    fi
    DEVICE_ARCH=$(adb shell "uname -m" 2>/dev/null | tr -d '\r\n')
    if [[ "$DEVICE_ARCH" != "aarch64" ]]; then
        echo "WARNING: Device reports arch '$DEVICE_ARCH', expected aarch64"
    fi
fi

# ── Resolve primals and config ───────────────────────────────────────────────

PRIMALS=$(primals_for_composition "$COMPOSITION")

if [[ -z "$FAMILY_ID" ]]; then
    if [[ -n "$BEACON_SEED" && -f "$BEACON_SEED" ]]; then
        FAMILY_ID=$(b3sum --no-names "$BEACON_SEED" | head -c 8)
    else
        FAMILY_ID=$(echo "$NODE_ID-$(date +%s)" | md5sum | head -c 8)
    fi
fi

echo "plasmidBin Pixel deploy — $(date -Iseconds)"
echo "Device:      $(adb get-serialno 2>/dev/null || echo 'unknown')"
echo "Composition: $COMPOSITION ($PRIMALS)"
echo "Family ID:   $FAMILY_ID"
echo "Node ID:     $NODE_ID"
echo "Dark Forest: $DARK_FOREST"
echo "Remote dir:  $REMOTE_DIR"
echo ""

# ── Phase 1: Verify local aarch64 binaries ──────────────────────────────────

echo "=== Phase 1: Verify aarch64 binaries ==="

MISSING=0
for p in $PRIMALS; do
    if [[ ! -f "$AARCH64_DIR/$p" ]]; then
        echo "  ERROR: Missing $AARCH64_DIR/$p"
        MISSING=$((MISSING + 1))
    else
        echo "  OK: $p ($(du -h "$AARCH64_DIR/$p" | cut -f1))"
    fi
done

if [[ $MISSING -gt 0 ]]; then
    echo ""
    echo "Build aarch64 binaries first:"
    echo "  ./scripts/build_ecosystem_genomeBin.sh --aarch64"
    echo "  ./harvest.sh --arch aarch64"
    exit 1
fi
echo ""

# ── Phase 2: Push binaries to device ────────────────────────────────────────

echo "=== Phase 2: Push binaries to device ==="

adb_sh "mkdir -p $REMOTE_PRIMALS $REMOTE_RUNTIME"

for p in $PRIMALS; do
    echo "  Pushing $p..."
    run adb push "$AARCH64_DIR/$p" "$REMOTE_PRIMALS/$p"
done
adb_sh "chmod +x $REMOTE_PRIMALS/*"

if [[ -n "$BEACON_SEED" && -f "$BEACON_SEED" ]]; then
    echo "  Pushing beacon seed..."
    run adb push "$BEACON_SEED" "$REMOTE_DIR/.beacon.seed"
    adb_sh "chmod 600 $REMOTE_DIR/.beacon.seed"
fi
echo ""

# ── Phase 3: Generate and push startup script ───────────────────────────────

echo "=== Phase 3: Generate startup script ==="

STARTUP="#!/system/bin/sh
export FAMILY_ID=\"$FAMILY_ID\"
export NODE_ID=\"$NODE_ID\"
export ECOPRIMALS_PLASMID_BIN=\"$REMOTE_DIR\"
export HOME=\"$REMOTE_RUNTIME\"
export TMPDIR=\"$REMOTE_RUNTIME\"
export XDG_RUNTIME_DIR=\"$REMOTE_RUNTIME\"
export BIOMEOS_SOCKET_DIR=\"$REMOTE_RUNTIME/sockets\"
export NESTGATE_SOCKET=\"$REMOTE_RUNTIME/sockets/nestgate-\$FAMILY_ID.sock\"
export BIOMEOS_API_SOCKET_PATH=\"$REMOTE_RUNTIME/sockets/biomeos-api-\$FAMILY_ID.sock\"
export NEURAL_API_SOCKET=\"$REMOTE_RUNTIME/sockets/neural-api-\$FAMILY_ID.sock\"
mkdir -p $REMOTE_RUNTIME $REMOTE_RUNTIME/biomeos $REMOTE_RUNTIME/pid $REMOTE_RUNTIME/sockets
cd $REMOTE_RUNTIME
"

if [[ -n "$BEACON_SEED" && -f "$BEACON_SEED" ]]; then
    STARTUP+="export FAMILY_SEED=\$(cat $REMOTE_DIR/.beacon.seed)
export BEARDOG_FAMILY_SEED=\$(cat $REMOTE_DIR/.beacon.seed)
"
else
    STARTUP+="export FAMILY_SEED=\"\$FAMILY_ID\"
export BEARDOG_FAMILY_SEED=\"\$FAMILY_ID\"
"
fi

if $DARK_FOREST; then
    STARTUP+="export SONGBIRD_DARK_FOREST=true
export SONGBIRD_AUTO_DISCOVERY=true
"
fi

STARTUP+="
echo \"Starting primal composition: $COMPOSITION\"
echo \"Family: \$FAMILY_ID  Node: \$NODE_ID  Dark Forest: $DARK_FOREST\"
echo \"\"

# Kill existing
for p in $PRIMALS; do
    pkill -f \"$REMOTE_PRIMALS/\$p\" 2>/dev/null || true
done
sleep 1
"

for p in $PRIMALS; do
    PORT=$(port_for_primal "$p")
    case "$p" in
        beardog)
            STARTUP+="
echo \"Starting beardog (abstract socket + TCP $PORT)...\"
$REMOTE_PRIMALS/beardog server \\
    --abstract \\
    --family-id \$FAMILY_ID \\
    --listen 0.0.0.0:$PORT \\
    > /data/local/tmp/beardog.log 2>&1 &
BEARDOG_PID=\$!
echo \"  PID: \$BEARDOG_PID\"
sleep 2
"
            ;;
        songbird)
            STARTUP+="
echo \"Starting songbird (HTTP $PORT)...\"
export BEARDOG_SOCKET=\"@biomeos_beardog\"
export BEARDOG_MODE=direct
export SONGBIRD_SECURITY_PROVIDER=beardog
$REMOTE_PRIMALS/songbird server \\
    --port $PORT \\
    > /data/local/tmp/songbird.log 2>&1 &
echo \"  PID: \$!\"
sleep 2
"
            ;;
        nestgate)
            STARTUP+="
echo \"Starting nestgate (TCP $PORT + abstract socket — Android SELinux)...\"
export NESTGATE_FAMILY_ID=\"\$FAMILY_ID\"
export NESTGATE_JWT_SECRET=\"plasmidbin-pixel-\$FAMILY_ID\"
$REMOTE_PRIMALS/nestgate server \\
    --dev \\
    --abstract \\
    --port $PORT \\
    --family-id \$FAMILY_ID \\
    > /data/local/tmp/nestgate.log 2>&1 &
echo \"  PID: \$!\"
sleep 2
"
            ;;
        toadstool)
            STARTUP+="
echo \"Starting toadstool (TCP $PORT)...\"
export TOADSTOOL_FAMILY_ID=\"\$FAMILY_ID\"
export TOADSTOOL_NODE_ID=\"\$NODE_ID\"
export TOADSTOOL_SECURITY_WARNING_ACKNOWLEDGED=1
export TOADSTOOL_SOCKET=\"\$BIOMEOS_SOCKET_DIR/compute-\$FAMILY_ID.sock\"
$REMOTE_PRIMALS/toadstool server \\
    --port $PORT \\
    > /data/local/tmp/toadstool.log 2>&1 &
echo \"  PID: \$!\"
sleep 2
"
            ;;
        squirrel)
            STARTUP+="
echo \"Starting squirrel (HTTP $PORT)...\"
export SQUIRREL_MODE=server
$REMOTE_PRIMALS/squirrel server \\
    --port $PORT \\
    --bind 0.0.0.0 \\
    > /data/local/tmp/squirrel.log 2>&1 &
echo \"  PID: \$!\"
sleep 2
"
            ;;
        biomeos)
            STARTUP+="
echo \"Starting biomeOS (TCP $PORT — Android SELinux, skip UDS)...\"
export BIOMEOS_BTSP_ENFORCE=0
$REMOTE_PRIMALS/biomeos neural-api \\
    --port $PORT \\
    --bind 0.0.0.0 \\
    --btsp-optional \\
    > /data/local/tmp/biomeos.log 2>&1 &
echo \"  PID: \$!\"
sleep 2
"
            ;;
        barracuda)
            STARTUP+="
echo \"Starting barracuda (TCP $PORT, no UDS — Android SELinux)...\"
export BARRACUDA_FAMILY_ID=\"\$FAMILY_ID\"
export BARRACUDA_NODE_ID=\"\$NODE_ID\"
$REMOTE_PRIMALS/barracuda server \\
    --port $PORT \\
    --no-unix \\
    > /data/local/tmp/barracuda.log 2>&1 &
echo \"  PID: \$!\"
sleep 1
"
            ;;
        coralreef)
            STARTUP+="
echo \"Starting coralreef (TCP $PORT only — Android SELinux)...\"
export CORALREEF_FAMILY_ID=\"\$FAMILY_ID\"
export TRANSPORT_ENDPOINT='{\"transport\":\"tcp\",\"host\":\"0.0.0.0\",\"port\":$PORT}'
$REMOTE_PRIMALS/coralreef server \\
    --rpc-bind 0.0.0.0:$PORT \\
    > /data/local/tmp/coralreef.log 2>&1 &
unset TRANSPORT_ENDPOINT
echo \"  PID: \$!\"
sleep 1
"
            ;;
        rhizocrypt)
            STARTUP+="
echo \"Starting rhizocrypt (TCP $PORT)...\"
export RHIZOCRYPT_FAMILY_ID=\"\$FAMILY_ID\"
$REMOTE_PRIMALS/rhizocrypt server \\
    --port $PORT \\
    > /data/local/tmp/rhizocrypt.log 2>&1 &
echo \"  PID: \$!\"
sleep 1
"
            ;;
        loamspine)
            STARTUP+="
echo \"Starting loamspine (TCP $PORT)...\"
$REMOTE_PRIMALS/loamspine server \\
    --port $PORT \\
    > /data/local/tmp/loamspine.log 2>&1 &
echo \"  PID: \$!\"
sleep 1
"
            ;;
        sweetgrass)
            STARTUP+="
echo \"Starting sweetgrass (TCP $PORT)...\"
$REMOTE_PRIMALS/sweetgrass server \\
    --port $PORT \\
    > /data/local/tmp/sweetgrass.log 2>&1 &
echo \"  PID: \$!\"
sleep 1
"
            ;;
        skunkbat)
            STARTUP+="
echo \"Starting skunkbat (TCP $PORT, no UDS — Android SELinux)...\"
export BEARDOG_HOST=\"127.0.0.1\"
export BEARDOG_PORT=\"$BEARDOG_PORT\"
$REMOTE_PRIMALS/skunkbat server \\
    --port $PORT \\
    --no-uds \\
    > /data/local/tmp/skunkbat.log 2>&1 &
echo \"  PID: \$!\"
sleep 1
"
            ;;
        petaltongue)
            STARTUP+="
echo \"Starting petaltongue (TCP $PORT — Android SELinux, skip UDS)...\"
export TRANSPORT_ENDPOINT='{\"transport\":\"tcp\",\"host\":\"0.0.0.0\",\"port\":$PORT}'
$REMOTE_PRIMALS/petaltongue server \\
    --port $PORT \\
    --bind 0.0.0.0 \\
    > /data/local/tmp/petaltongue.log 2>&1 &
unset TRANSPORT_ENDPOINT
echo \"  PID: \$!\"
sleep 1
"
            ;;
        *)
            STARTUP+="
echo \"Starting $p (TCP $PORT — generic handler)...\"
$REMOTE_PRIMALS/$p server \\
    --port $PORT \\
    > /data/local/tmp/$p.log 2>&1 &
echo \"  PID: \$!\"
sleep 1
"
            ;;
    esac
done

STARTUP+="
echo \"\"
echo \"=== Pixel Gate Ready ===\"
echo \"Composition: $COMPOSITION\"
echo \"Primals running:\"
for p in $PRIMALS; do
    pid=\$(pgrep -f \"$REMOTE_PRIMALS/\$p\" 2>/dev/null | head -1)
    if [ -n \"\$pid\" ]; then
        echo \"  \$p: PID \$pid\"
    else
        echo \"  \$p: FAILED (check /data/local/tmp/\$p.log)\"
    fi
done
echo \"\"
echo \"TCP endpoints:\"
"

for p in $PRIMALS; do
    PORT=$(port_for_primal "$p")
    STARTUP+="echo \"  $p: tcp://0.0.0.0:$PORT\"
"
done

if $DRY_RUN; then
    echo "  [dry-run] Startup script:"
    echo "$STARTUP" | head -30
    echo "  ..."
else
    echo "$STARTUP" | adb shell "cat > $REMOTE_DIR/start_gate.sh && chmod +x $REMOTE_DIR/start_gate.sh"
    echo "  Pushed start_gate.sh to device"
fi
echo ""

# ── Phase 4: Start primals on device ────────────────────────────────────────

echo "=== Phase 4: Start primals ==="

if $DRY_RUN; then
    echo "  [dry-run] Would run: adb shell sh $REMOTE_DIR/start_gate.sh"
else
    adb shell "sh $REMOTE_DIR/start_gate.sh"
fi
echo ""

# ── Phase 5: ADB port forwarding ────────────────────────────────────────────

if ! $SKIP_FORWARD; then
    echo "=== Phase 5: ADB port forwarding ==="
    for p in $PRIMALS; do
        PORT=$(port_for_primal "$p")
        LOCAL_PORT=$((PORT + LOCAL_PORT_OFFSET))
        if [[ "$PORT" != "0" ]]; then
            run adb forward tcp:$LOCAL_PORT tcp:$PORT
            echo "  $p: localhost:$LOCAL_PORT -> device:$PORT"
        fi
    done
    echo ""
    echo "Access primals via localhost:"
    for p in $PRIMALS; do
        PORT=$(port_for_primal "$p")
        LOCAL_PORT=$((PORT + LOCAL_PORT_OFFSET))
        echo "  $p: tcp://localhost:$LOCAL_PORT"
    done
fi

echo ""

# ── Phase 6: Quick probe ────────────────────────────────────────────────────

echo "=== Phase 6: Quick probe ==="

if ! $DRY_RUN; then
    sleep 2
    ALL_OK=true
    for p in $PRIMALS; do
        PORT=$(port_for_primal "$p")
        LOCAL_PORT=$((PORT + LOCAL_PORT_OFFSET))
        if timeout 3 bash -c "echo '' > /dev/tcp/localhost/$LOCAL_PORT" 2>/dev/null; then
            echo "  $p (localhost:$LOCAL_PORT via ADB): REACHABLE"
        else
            echo "  $p (localhost:$LOCAL_PORT via ADB): NOT REACHABLE"
            ALL_OK=false
        fi
    done

    echo ""
    if $ALL_OK; then
        echo "Pixel gate deployed and reachable via ADB forward."
    else
        echo "Some primals not reachable. Check device logs:"
        echo "  adb shell cat /data/local/tmp/beardog.log"
        echo "  adb shell cat /data/local/tmp/songbird.log"
    fi
else
    for p in $PRIMALS; do
        PORT=$(port_for_primal "$p")
        LOCAL_PORT=$((PORT + LOCAL_PORT_OFFSET))
        echo "  [dry-run] Would probe localhost:$LOCAL_PORT ($p)"
    done
fi

echo ""
echo "=== Deploy complete ==="
echo "Device script: $REMOTE_DIR/start_gate.sh"
echo "Device logs:   adb shell 'cat /data/local/tmp/*.log'"
if [[ $LOCAL_PORT_OFFSET -gt 0 ]]; then
    echo "Validate:      ./validate_gate.sh localhost (ports offset by +$LOCAL_PORT_OFFSET)"
else
    echo "Validate:      ./validate_gate.sh localhost"
fi
echo "Stop:          $0 --stop"
echo ""
echo "For hotspot LAN access, find Pixel IP:"
echo "  adb shell 'ip addr show wlan0 | grep inet'"
echo "Then validate from any machine on the same hotspot:"
echo "  ./validate_gate.sh <pixel-ip>"
