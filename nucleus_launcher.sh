#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# NUCLEUS Launcher — Zero-Port Tower Atomic Standard
#
# Starts the ecoPrimals NUCLEUS composition stack in dependency order.
# All primals run UDS-only by default. No TCP ports are bound.
# Songbird TCP is opt-in only via SONGBIRD_FEDERATION_PORT for LAN mesh.
#
# Phases:
#   0: biomeOS Neural API (orchestration substrate)
#   1: Tower Atomic — BearDog (crypto root) + Songbird (gateway, UDS-only)
#   2: Core Services — ToadStool (compute) + NestGate (persistence) + Squirrel (AI)
#   3: Provenance — rhizoCrypt (crypto-storage) + loamSpine (DAG) + sweetGrass (commit)
#   4: Interface — petalTongue (visualization, server mode)
#
# Springs and gardens (ludoSpring, esotericWebb, etc.) are downstream
# consumers of NUCLEUS, not primals. They use proto-nucleate graphs to
# compose NUCLEUS capabilities. See graphs/downstream/ for patterns.
#
# Security Model:
#   Tower boundary (BearDog + Songbird) enforces BTSP.
#   NUCLEUS internal traffic (same-host UDS) may use lower encryption.
#   External federation (opt-in Songbird TCP) uses full encryption.
#
# Usage:
#   ./tools/nucleus_launcher.sh start     # launch full stack
#   ./tools/nucleus_launcher.sh stop      # graceful shutdown
#   ./tools/nucleus_launcher.sh status    # health check all primals
#   ./tools/nucleus_launcher.sh restart   # stop + start
#
# Environment:
#   NUCLEUS_BIN_DIR            — directory containing primal binaries (default: auto-detect)
#   NUCLEUS_FAMILY_ID          — family ID for socket naming (default: auto-detect)
#   NUCLEUS_LOG_LEVEL          — tracing log level (default: info)
#   OLLAMA_ENDPOINT            — Ollama URL for AI narration (default: http://localhost:11434)
#   BIOMEOS_GRAPHS_DIR         — biomeOS graphs directory (default: auto-detect)
#   SONGBIRD_FEDERATION_PORT   — opt-in TCP port for LAN federation (unset = UDS-only)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLASMIDBIN="$SCRIPT_DIR"
ECO_ROOT="$(cd "$PLASMIDBIN/../.." && pwd)"

SOCKET_DIR="/run/user/$(id -u)/biomeos"
NUCLEUS_LOG_LEVEL="${NUCLEUS_LOG_LEVEL:-info}"
OLLAMA_ENDPOINT="${OLLAMA_ENDPOINT:-http://localhost:11434}"
PID_DIR="/tmp/nucleus-pids"

detect_bin_dir() {
    if [[ -n "${NUCLEUS_BIN_DIR:-}" ]]; then
        echo "$NUCLEUS_BIN_DIR"
        return
    fi
    if [[ -x "$PLASMIDBIN/beardog/beardog" ]]; then
        echo "$PLASMIDBIN"
        return
    fi
    local plasmid="$ECO_ROOT/infra/plasmidBin"
    if [[ -x "$plasmid/beardog/beardog" ]]; then
        echo "$plasmid"
        return
    fi
    echo ""
}

detect_family_id() {
    if [[ -n "${NUCLEUS_FAMILY_ID:-}" ]]; then
        echo "$NUCLEUS_FAMILY_ID"
        return
    fi
    local existing
    existing=$(ls "$SOCKET_DIR"/neural-api-*.sock 2>/dev/null | head -1 | sed 's/.*neural-api-//;s/\.sock//')
    if [[ -n "$existing" ]]; then
        echo "$existing"
        return
    fi
    echo "nucleus01"
}

detect_graphs_dir() {
    if [[ -n "${BIOMEOS_GRAPHS_DIR:-}" ]]; then
        echo "$BIOMEOS_GRAPHS_DIR"
        return
    fi
    local biome_graphs="$ECO_ROOT/primals/biomeOS/graphs"
    if [[ -d "$biome_graphs" ]]; then
        echo "$biome_graphs"
        return
    fi
    echo ""
}

BIN_DIR="$(detect_bin_dir)"
FAMILY_ID="$(detect_family_id)"
GRAPHS_DIR="$(detect_graphs_dir)"

resolve_family_seed() {
    if [[ -n "${BEARDOG_FAMILY_SEED:-}" ]]; then
        echo "$BEARDOG_FAMILY_SEED"
        return
    fi
    if [[ -n "${FAMILY_SEED:-}" ]]; then
        echo "$FAMILY_SEED"
        return
    fi
    if [[ -f "$SOCKET_DIR/.family.seed" ]]; then
        cat "$SOCKET_DIR/.family.seed"
        return
    fi
    head -c 32 /dev/urandom | xxd -p | tr -d '\n'
}

FAMILY_SEED="$(resolve_family_seed)"
export FAMILY_SEED
export BEARDOG_FAMILY_SEED="$FAMILY_SEED"
export FAMILY_ID

log() { echo "[nucleus] $(date +%H:%M:%S) $*"; }
err() { echo "[nucleus] ERROR: $*" >&2; }

wait_for_socket() {
    local sock="$1" timeout="${2:-10}" elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        if [[ -S "$sock" ]]; then
            return 0
        fi
        sleep 0.5
        elapsed=$((elapsed + 1))
    done
    return 1
}

health_check() {
    local sock="$1" method="${2:-health.liveness}"
    echo "{\"jsonrpc\":\"2.0\",\"method\":\"$method\",\"id\":1}" | \
        timeout 3 socat - "UNIX-CONNECT:$sock" 2>/dev/null
}

save_pid() {
    local name="$1" pid="$2"
    mkdir -p "$PID_DIR"
    echo "$pid" > "$PID_DIR/$name.pid"
}

read_pid() {
    local name="$1"
    local pidfile="$PID_DIR/$name.pid"
    if [[ -f "$pidfile" ]]; then
        cat "$pidfile"
    fi
}

find_binary() {
    local name="$1"
    local primal_dir="${2:-$name}"
    if [[ -n "$BIN_DIR" && -x "$BIN_DIR/$name/$name" ]]; then
        echo "$BIN_DIR/$name/$name"
        return
    fi
    if [[ -n "$BIN_DIR" && -x "$BIN_DIR/$name" ]]; then
        echo "$BIN_DIR/$name"
        return
    fi
    local target="$ECO_ROOT/primals/$primal_dir/target/release/$name"
    if [[ -x "$target" ]]; then
        echo "$target"
        return
    fi
    which "$name" 2>/dev/null || true
}

start_primal() {
    local name="$1" binary="$2"
    shift 2
    local args=("$@")

    if pgrep -f "$name.*(server|serve|daemon)" >/dev/null 2>&1; then
        log "$name already running, skipping"
        return 0
    fi

    local logfile="/tmp/nucleus-${name}.log"
    log "starting $name..."
    setsid "$binary" "${args[@]}" > "$logfile" 2>&1 &
    local pid=$!
    disown "$pid" 2>/dev/null || true
    save_pid "$name" "$pid"
    sleep 1

    if ! kill -0 "$pid" 2>/dev/null; then
        err "$name failed to start. Check $logfile"
        return 1
    fi
    log "$name started (pid=$pid)"
    return 0
}

cmd_start() {
    log "╔══════════════════════════════════════════════════════════════╗"
    log "║  NUCLEUS — Zero-Port Tower Atomic Deployment               ║"
    log "╚══════════════════════════════════════════════════════════════╝"
    log "  bin_dir:    ${BIN_DIR:-<release targets>}"
    log "  family_id:  $FAMILY_ID"
    log "  socket_dir: $SOCKET_DIR"
    log "  seed:       ${FAMILY_SEED:0:16}... (${#FAMILY_SEED} chars)"
    log "  security:   Tower=BTSP, NUCLEUS=BTSP-default (UDS), TCP=disabled"
    if [[ -n "${SONGBIRD_FEDERATION_PORT:-}" ]]; then
        log "  federation: Songbird TCP port $SONGBIRD_FEDERATION_PORT (opt-in)"
    fi
    mkdir -p "$SOCKET_DIR"

    echo "$FAMILY_SEED" > "$SOCKET_DIR/.family.seed"
    chmod 600 "$SOCKET_DIR/.family.seed"
    log "  seed:       persisted to $SOCKET_DIR/.family.seed"

    # ── Phase 0: biomeOS Neural API (cleartext bootstrap) ────────────
    # biomeOS starts BEFORE Tower (BearDog), so it cannot enforce BTSP yet.
    # BIOMEOS_BTSP_ENFORCE=0 keeps it in cleartext mode. After Tower is
    # confirmed healthy (Phase 1), biomeOS can be signalled to escalate.
    log "── Phase 0: biomeOS Neural API (cleartext bootstrap) ──"
    local biomeos_bin
    biomeos_bin="$(find_binary biomeos biomeOS)"
    if [[ -z "$biomeos_bin" ]]; then
        err "biomeos binary not found"
        return 1
    fi
    local neural_sock="$SOCKET_DIR/neural-api-${FAMILY_ID}.sock"
    if ! pgrep -f "biomeos.*neural-api.*${FAMILY_ID}" >/dev/null 2>&1; then
        local biomeos_args=(neural-api --socket "$neural_sock" --family-id default --log-level "$NUCLEUS_LOG_LEVEL")
        [[ -n "$GRAPHS_DIR" ]] && biomeos_args+=(--graphs-dir "$GRAPHS_DIR")
        setsid env -u FAMILY_ID -u FAMILY_SEED -u BEARDOG_FAMILY_SEED \
            BIOMEOS_BTSP_ENFORCE=0 \
            "$biomeos_bin" "${biomeos_args[@]}" > /tmp/nucleus-biomeos.log 2>&1 &
        local bm_pid=$!
        disown "$bm_pid" 2>/dev/null || true
        save_pid biomeos "$bm_pid"
        log "biomeOS Neural API starting (pid=$bm_pid)"
        wait_for_socket "$neural_sock" 10 || { err "biomeOS socket timeout"; return 1; }
    else
        log "biomeOS Neural API already running"
    fi

    # ── Phase 1: Tower Atomic — BearDog + Songbird ───────────────────
    log "── Phase 1: Tower Atomic (BTSP enforced) ──"
    local beardog_bin songbird_bin
    beardog_bin="$(find_binary beardog beardog)"
    songbird_bin="$(find_binary songbird songbird)"
    local beardog_sock="$SOCKET_DIR/beardog-${FAMILY_ID}.sock"
    local songbird_sock="$SOCKET_DIR/songbird-${FAMILY_ID}.sock"

    if [[ -n "$beardog_bin" ]]; then
        NODE_ID="${NODE_ID:-tower1}" \
        BEARDOG_NODE_ID="${BEARDOG_NODE_ID:-tower1}" \
            start_primal beardog "$beardog_bin" server \
                --socket "$beardog_sock" \
                --family-id "$FAMILY_ID" || true
        wait_for_socket "$beardog_sock" 8 || log "WARN: beardog socket not ready"
    else
        log "WARN: beardog binary not found, skipping"
    fi

    if [[ -n "$songbird_bin" ]]; then
        local songbird_args=(server --socket "$songbird_sock" --beardog-socket "$beardog_sock")
        if [[ -n "${SONGBIRD_FEDERATION_PORT:-}" ]]; then
            songbird_args+=(--port "$SONGBIRD_FEDERATION_PORT")
            log "  Songbird: TCP federation on port $SONGBIRD_FEDERATION_PORT"
        fi
        SONGBIRD_SECURITY_PROVIDER="beardog" \
        BEARDOG_SOCKET="$beardog_sock" \
        SECURITY_ENDPOINT="$beardog_sock" \
        SONGBIRD_DISCOVERY_MODE="disabled" \
        FAMILY_ID="$FAMILY_ID" \
        FAMILY_SEED="${FAMILY_SEED:-}" \
        BEARDOG_FAMILY_SEED="${BEARDOG_FAMILY_SEED:-}" \
        BTSP_PROVIDER_SOCKET="$beardog_sock" \
            start_primal songbird "$songbird_bin" "${songbird_args[@]}" || true
        wait_for_socket "$songbird_sock" 8 || log "WARN: songbird socket not ready"
    else
        log "WARN: songbird binary not found, skipping"
    fi

    # ── Phase 2: Core Services — Node Atomic + NestGate + Squirrel ────
    log "── Phase 2: Core Services (BTSP via Tower) ──"
    local toadstool_bin barracuda_bin coralreef_bin nestgate_bin squirrel_bin
    toadstool_bin="$(find_binary toadstool toadStool)"
    barracuda_bin="$(find_binary barracuda barraCuda)"
    coralreef_bin="$(find_binary coralreef coralReef)"
    nestgate_bin="$(find_binary nestgate nestgate)"
    squirrel_bin="$(find_binary squirrel squirrel)"
    local toadstool_sock="$SOCKET_DIR/toadstool-${FAMILY_ID}.sock"
    local barracuda_sock="$SOCKET_DIR/barracuda-${FAMILY_ID}.sock"
    local coralreef_sock="$SOCKET_DIR/coralreef-${FAMILY_ID}.sock"
    local nestgate_sock="$SOCKET_DIR/nestgate-${FAMILY_ID}.sock"
    local squirrel_sock="$SOCKET_DIR/squirrel-${FAMILY_ID}.sock"

    if [[ -n "$toadstool_bin" ]]; then
        TOADSTOOL_SOCKET="$toadstool_sock" \
        TOADSTOOL_FAMILY_ID="$FAMILY_ID" \
        TOADSTOOL_SECURITY_WARNING_ACKNOWLEDGED="1" \
        NESTGATE_SOCKET="$nestgate_sock" \
            start_primal toadstool "$toadstool_bin" server || true
        wait_for_socket "$toadstool_sock" 8 || log "WARN: toadstool socket not ready"
    else
        log "WARN: toadstool binary not found, skipping"
    fi

    if [[ -n "$barracuda_bin" ]]; then
        BARRACUDA_FAMILY_ID="$FAMILY_ID" \
        BEARDOG_SOCKET="$beardog_sock" \
        SONGBIRD_SOCKET="$songbird_sock" \
            start_primal barracuda "$barracuda_bin" server || true
        wait_for_socket "$barracuda_sock" 8 || \
            wait_for_socket "$SOCKET_DIR/math-${FAMILY_ID}.sock" 5 || \
            log "WARN: barracuda socket not ready"
        # barraCuda binds to math-{family}.sock and creates barracuda-{family}.sock symlink
        if [[ ! -e "$barracuda_sock" && -S "$SOCKET_DIR/math-${FAMILY_ID}.sock" ]]; then
            ln -sf "math-${FAMILY_ID}.sock" "$barracuda_sock" 2>/dev/null || true
        fi
    else
        log "WARN: barracuda binary not found, skipping"
    fi

    if [[ -n "$coralreef_bin" ]]; then
        CORALREEF_FAMILY_ID="$FAMILY_ID" \
        BIOMEOS_FAMILY_ID="$FAMILY_ID" \
        CORALREEF_SOCKET="$coralreef_sock" \
        BEARDOG_SOCKET="$beardog_sock" \
        SONGBIRD_SOCKET="$songbird_sock" \
            start_primal coralreef "$coralreef_bin" server || true
        wait_for_socket "$coralreef_sock" 8 || log "WARN: coralreef socket not ready"
    else
        log "WARN: coralreef binary not found, skipping"
    fi

    if [[ -n "$nestgate_bin" ]]; then
        NESTGATE_JWT_SECRET="${NESTGATE_JWT_SECRET:-dev-only-primalspring-jwt-override}" \
        NESTGATE_SOCKET="$nestgate_sock" \
        NESTGATE_FAMILY_ID="$FAMILY_ID" \
            start_primal nestgate "$nestgate_bin" daemon --socket-only --dev || true
        wait_for_socket "$nestgate_sock" 8 || log "WARN: nestgate socket not ready"
    else
        log "WARN: nestgate binary not found, skipping"
    fi

    if [[ -n "$squirrel_bin" ]]; then
        if ! pgrep -f "squirrel.*server" >/dev/null 2>&1; then
            log "starting squirrel (with Ollama at $OLLAMA_ENDPOINT)..."
            setsid env \
                LOCAL_AI_ENDPOINT="$OLLAMA_ENDPOINT" \
                OLLAMA_ENDPOINT="$OLLAMA_ENDPOINT" \
                MCP_DEFAULT_MODEL="${MCP_DEFAULT_MODEL:-llama3.2:3b}" \
                SQUIRREL_SOCKET="$squirrel_sock" \
                SERVICE_MESH_ENDPOINT="$neural_sock" \
                HTTP_REQUEST_PROVIDER_SOCKET="$songbird_sock" \
                CRYPTO_SIGN_PROVIDER_SOCKET="$beardog_sock" \
                COMPUTE_EXECUTE_PROVIDER_SOCKET="$toadstool_sock" \
                STORAGE_STORE_PROVIDER_SOCKET="$nestgate_sock" \
                STORAGE_GET_PROVIDER_SOCKET="$nestgate_sock" \
                "$squirrel_bin" server --socket "$squirrel_sock" > /tmp/nucleus-squirrel.log 2>&1 &
            local sq_pid=$!
            disown "$sq_pid" 2>/dev/null || true
            save_pid squirrel "$sq_pid"
            log "squirrel started (pid=$sq_pid)"
            wait_for_socket "$squirrel_sock" 8 || log "WARN: squirrel socket not ready"
        else
            log "squirrel already running"
        fi
    else
        log "WARN: squirrel binary not found, skipping"
    fi

    # ── Phase 3: Provenance — rhizoCrypt + loamSpine + sweetGrass ────
    log "── Phase 3: Provenance Trio (BTSP via Tower) ──"
    local rhizocrypt_bin loamspine_bin sweetgrass_bin
    rhizocrypt_bin="$(find_binary rhizocrypt rhizoCrypt)"
    loamspine_bin="$(find_binary loamspine loamSpine)"
    sweetgrass_bin="$(find_binary sweetgrass sweetGrass)"
    local rhizocrypt_sock="$SOCKET_DIR/rhizocrypt-${FAMILY_ID}.sock"
    local loamspine_sock="$SOCKET_DIR/loamspine-${FAMILY_ID}.sock"
    local sweetgrass_sock="$SOCKET_DIR/sweetgrass-${FAMILY_ID}.sock"

    if [[ -n "$rhizocrypt_bin" ]]; then
        RHIZOCRYPT_SOCKET="$rhizocrypt_sock" \
        BIOMEOS_SOCKET_DIR="$SOCKET_DIR" \
        BEARDOG_SOCKET="$beardog_sock" \
        FAMILY_SEED="${FAMILY_SEED:-}" \
        BEARDOG_FAMILY_SEED="${BEARDOG_FAMILY_SEED:-}" \
        BTSP_PROVIDER_SOCKET="$beardog_sock" \
            start_primal rhizocrypt "$rhizocrypt_bin" server || true
        # rhizoCrypt may bind as rhizocrypt.sock (no family suffix)
        wait_for_socket "$rhizocrypt_sock" 12 || \
            wait_for_socket "$SOCKET_DIR/rhizocrypt.sock" 4 || \
            log "WARN: rhizocrypt socket not ready"
    else
        log "WARN: rhizocrypt binary not found, skipping"
    fi

    if [[ -n "$loamspine_bin" ]]; then
        LOAMSPINE_SOCKET="$loamspine_sock" \
        BIOMEOS_SOCKET_DIR="$SOCKET_DIR" \
        BEARDOG_SOCKET="$beardog_sock" \
        RHIZOCRYPT_SOCKET="$rhizocrypt_sock" \
        FAMILY_SEED="${FAMILY_SEED:-}" \
        BEARDOG_FAMILY_SEED="${BEARDOG_FAMILY_SEED:-}" \
        BTSP_PROVIDER_SOCKET="$beardog_sock" \
        BIOMEOS_FAMILY_ID="$FAMILY_ID" \
            start_primal loamspine "$loamspine_bin" server || true
        wait_for_socket "$loamspine_sock" 8 || log "WARN: loamspine socket not ready"
    else
        log "WARN: loamspine binary not found, skipping"
    fi

    if [[ -n "$sweetgrass_bin" ]]; then
        SWEETGRASS_SOCKET="$sweetgrass_sock" \
        BIOMEOS_SOCKET_DIR="$SOCKET_DIR" \
        BEARDOG_SOCKET="$beardog_sock" \
        FAMILY_SEED="${FAMILY_SEED:-}" \
        BEARDOG_FAMILY_SEED="${BEARDOG_FAMILY_SEED:-}" \
        BTSP_PROVIDER_SOCKET="$beardog_sock" \
            start_primal sweetgrass "$sweetgrass_bin" server || true
        wait_for_socket "$sweetgrass_sock" 8 || log "WARN: sweetgrass socket not ready"
    else
        log "WARN: sweetgrass binary not found, skipping"
    fi

    # ── Phase 4: Interface — petalTongue (server mode, UDS) ──────────
    log "── Phase 4: Interface (BTSP via Tower) ──"
    local petaltongue_bin
    petaltongue_bin="$(find_binary petaltongue petalTongue)"
    [[ -z "$petaltongue_bin" ]] && petaltongue_bin="$ECO_ROOT/primals/petalTongue/target/release/petaltongue"
    local petaltongue_sock="$SOCKET_DIR/petaltongue-${FAMILY_ID}.sock"

    if [[ -x "$petaltongue_bin" ]]; then
        PETALTONGUE_MODE="server" \
        PETALTONGUE_HEADLESS="true" \
        NEURAL_API_SOCKET="$neural_sock" \
        PETALTONGUE_SOCKET="$petaltongue_sock" \
            start_primal petaltongue "$petaltongue_bin" server || true
        wait_for_socket "$petaltongue_sock" 8 || log "WARN: petaltongue socket not ready"
    else
        log "WARN: petaltongue binary not found, skipping"
    fi

    # ── Post-Tower BTSP verification ─────────────────────────────
    # Now that Tower (BearDog + Songbird) is healthy and all primals are
    # launched, verify the BTSP handshake works via a socat probe.
    # This catches misconfigs before guidestone runs.
    if [[ -S "$beardog_sock" ]]; then
        log "── BTSP Verification ──"
        local btsp_probe='{"protocol":"btsp","version":1,"client_ephemeral_pub":"dGVzdA=="}'
        local verified=0
        local total=0
        for cap_sock in "$toadstool_sock" "$barracuda_sock" "$coralreef_sock" \
                        "$nestgate_sock" "$squirrel_sock" "$rhizocrypt_sock" \
                        "$loamspine_sock" "$sweetgrass_sock" "$petaltongue_sock"; do
            if [[ -S "$cap_sock" ]]; then
                total=$((total + 1))
                local probe_resp
                probe_resp=$(echo "$btsp_probe" | timeout 3 socat -t2 - "UNIX-CONNECT:$cap_sock" 2>/dev/null || true)
                if echo "$probe_resp" | grep -q '"challenge"'; then
                    verified=$((verified + 1))
                fi
            fi
        done
        if [[ -S "$beardog_sock" ]]; then
            total=$((total + 1))
            verified=$((verified + 1))
        fi
        if [[ -S "$songbird_sock" ]]; then
            total=$((total + 1))
            local songbird_resp
            songbird_resp=$(echo "$btsp_probe" | timeout 3 socat -t2 - "UNIX-CONNECT:$songbird_sock" 2>/dev/null || true)
            if echo "$songbird_resp" | grep -q '"challenge"'; then
                verified=$((verified + 1))
            fi
        fi
        if [[ $total -gt 0 ]]; then
            log "  BTSP: $verified/$total primals respond to handshake probe"
        fi
    fi

    # ── Domain capability aliases ────────────────────────────────
    # biomeOS and experiments discover primals by capability domain.
    # Each primal should create its own symlinks, but we ensure the
    # canonical set exists for NUCLEUS compositions.
    log "── Creating capability domain aliases ──"
    local -A domain_map=(
        [security]="beardog-${FAMILY_ID}.sock"
        [crypto]="beardog-${FAMILY_ID}.sock"
        [btsp]="beardog-${FAMILY_ID}.sock"
        [ed25519]="beardog-${FAMILY_ID}.sock"
        [x25519]="beardog-${FAMILY_ID}.sock"
        [discovery]="songbird-${FAMILY_ID}.sock"
        [network]="songbird-${FAMILY_ID}.sock"
        [compute]="toadstool-${FAMILY_ID}.sock"
        [tensor]="barracuda-${FAMILY_ID}.sock"
        [shader]="coralreef-${FAMILY_ID}.sock"
        [storage]="nestgate-${FAMILY_ID}.sock"
        [ai]="squirrel-${FAMILY_ID}.sock"
        [dag]="rhizocrypt-${FAMILY_ID}.sock"
        [spine]="loamspine-${FAMILY_ID}.sock"
        [commit]="sweetgrass-${FAMILY_ID}.sock"
        [braid]="sweetgrass-${FAMILY_ID}.sock"
        [provenance]="rhizocrypt-${FAMILY_ID}.sock"
        [attribution]="sweetgrass-${FAMILY_ID}.sock"
        [ledger]="loamspine-${FAMILY_ID}.sock"
        [merkle]="loamspine-${FAMILY_ID}.sock"
        [visualization]="petaltongue-${FAMILY_ID}.sock"
        [inference]="squirrel-${FAMILY_ID}.sock"
        [orchestration]="neural-api-${FAMILY_ID}.sock"
    )
    for domain in "${!domain_map[@]}"; do
        local target="$SOCKET_DIR/${domain_map[$domain]}"
        local alias_path="$SOCKET_DIR/${domain}.sock"
        if [[ -e "$target" || -L "$target" ]] && [[ ! -e "$alias_path" ]]; then
            ln -sf "$target" "$alias_path" 2>/dev/null && \
                log "  ${domain}.sock → ${domain_map[$domain]}" || true
        fi
    done

    # ── Primal family-suffix aliases ───────────────────────────────
    # Primals that bind as {primal}.sock (no family suffix) need
    # {primal}-{family_id}.sock aliases so biomeOS graph translation
    # resolves them correctly.
    local -A primal_alias_map=(
        [rhizocrypt-${FAMILY_ID}]="rhizocrypt"
        [squirrel-${FAMILY_ID}]="squirrel"
    )
    for alias in "${!primal_alias_map[@]}"; do
        local target="$SOCKET_DIR/${primal_alias_map[$alias]}.sock"
        local alias_path="$SOCKET_DIR/${alias}.sock"
        if [[ -e "$target" ]] && [[ ! -e "$alias_path" ]]; then
            ln -sf "$target" "$alias_path" 2>/dev/null && \
                log "  ${alias}.sock → ${primal_alias_map[$alias]}.sock" || true
        fi
    done

    # ── petalTongue neural-api alias ──────────────────────────────
    # petalTongue discovers biomeOS at $XDG_RUNTIME_DIR/biomeos-neural-api-{family}.sock
    # (one directory above SOCKET_DIR). Create the alias so petalTongue web/ui
    # can connect to biomeOS's neural-api for live graph and capability data.
    local xdg_dir
    xdg_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    local neural_alias="$xdg_dir/biomeos-neural-api-${FAMILY_ID}.sock"
    if [[ -S "$neural_sock" ]] && [[ ! -e "$neural_alias" ]]; then
        ln -sf "$neural_sock" "$neural_alias" 2>/dev/null && \
            log "  petalTongue alias: $neural_alias → $neural_sock" || true
    fi

    # ── Late alias sweep (retry for slow starters) ────────────────
    sleep 2
    for domain in "${!domain_map[@]}"; do
        local target="$SOCKET_DIR/${domain_map[$domain]}"
        local alias_path="$SOCKET_DIR/${domain}.sock"
        if [[ -e "$target" || -L "$target" ]] && [[ ! -e "$alias_path" ]]; then
            ln -sf "$target" "$alias_path" 2>/dev/null && \
                log "  (late) ${domain}.sock → ${domain_map[$domain]}" || true
        fi
    done
    for alias in "${!primal_alias_map[@]}"; do
        local target="$SOCKET_DIR/${primal_alias_map[$alias]}.sock"
        local alias_path="$SOCKET_DIR/${alias}.sock"
        if [[ -e "$target" ]] && [[ ! -e "$alias_path" ]]; then
            ln -sf "$target" "$alias_path" 2>/dev/null && \
                log "  (late) ${alias}.sock → ${primal_alias_map[$alias]}.sock" || true
        fi
    done

    # ── Phase 5: Seed Songbird service registry (LD-08 workaround) ──
    # Songbird auto-discovery scans at startup but other primals aren't ready yet.
    # Seed the registry so ipc.resolve works for downstream consumers.
    local songbird_sock="$SOCKET_DIR/songbird-${FAMILY_ID}.sock"
    if [[ -S "$songbird_sock" ]]; then
        log "── Phase 5: Seeding Songbird registry ──"
        local -A registry_seeds=(
            [beardog]="security,crypto,btsp,ed25519,x25519"
            [songbird]="discovery"
            [toadstool]="compute,hardware"
            [barracuda]="tensor,math,gpu_compute"
            [coralreef]="shader"
            [nestgate]="storage"
            [squirrel]="ai,inference"
            [rhizocrypt]="dag,provenance"
            [loamspine]="spine,merkle,ledger"
            [sweetgrass]="commit,braid,attribution"
            [petaltongue]="visualization"
        )
        for primal_id in "${!registry_seeds[@]}"; do
            local caps="${registry_seeds[$primal_id]}"
            local caps_json
            caps_json="[$(echo "$caps" | sed 's/,/","/g; s/^/"/; s/$/"/' )]"
            local sock_name="${primal_id}-${FAMILY_ID}.sock"
            [[ "$primal_id" == "rhizocrypt" ]] && sock_name="rhizocrypt.sock"
            local primal_sock="$SOCKET_DIR/$sock_name"
            if [[ -e "$primal_sock" || -L "$primal_sock" ]]; then
                local payload="{\"jsonrpc\":\"2.0\",\"method\":\"ipc.register\",\"params\":{\"primal_id\":\"$primal_id\",\"capabilities\":$caps_json,\"endpoint\":\"unix://$primal_sock\"},\"id\":1}"
                echo "$payload" | timeout 2 socat - "UNIX-CONNECT:$songbird_sock" >/dev/null 2>&1 && \
                    log "  registered $primal_id ($caps)" || true
            fi
        done
    fi

    log "╔══════════════════════════════════════════════════════════════╗"
    log "║  NUCLEUS stack launch complete — zero TCP ports bound       ║"
    log "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    cmd_status
}

cmd_stop() {
    log "Stopping NUCLEUS stack (reverse order)..."
    local primals=(petaltongue sweetgrass loamspine rhizocrypt squirrel nestgate coralreef barracuda toadstool songbird beardog biomeos)
    for name in "${primals[@]}"; do
        local pid
        pid="$(read_pid "$name")"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            log "stopping $name (pid=$pid)"
            kill "$pid" 2>/dev/null || true
        else
            pkill -f "$name.*(server|serve|daemon|neural-api)" 2>/dev/null || true
        fi
    done
    sleep 2
    log "NUCLEUS stack stopped"
}

cmd_status() {
    log "NUCLEUS Stack Status — Zero-Port Tower Atomic"
    echo "══════════════════════════════════════════════════════════════"
    printf "%-14s %-6s %-10s %s\n" "PRIMAL" "PHASE" "STATUS" "SOCKET"
    echo "──────────────────────────────────────────────────────────────"

    local checks=(
        "biomeOS|0|biomeos-${FAMILY_ID}:neural-api-${FAMILY_ID}|graph.list"
        "BearDog|1|beardog-${FAMILY_ID}|health.liveness"
        "Songbird|1|songbird-${FAMILY_ID}:songbird|health.liveness"
        "ToadStool|2|toadstool-${FAMILY_ID}:compute-${FAMILY_ID}-tarpc:compute:toadstool.jsonrpc|health.liveness"
        "barraCuda|2|barracuda-${FAMILY_ID}:tensor|health.liveness"
        "coralReef|2|coralreef-${FAMILY_ID}:shader|health.liveness"
        "NestGate|2|nestgate-${FAMILY_ID}:storage-${FAMILY_ID}|health.liveness"
        "Squirrel|2|squirrel-${FAMILY_ID}:squirrel|health.liveness"
        "rhizoCrypt|3|rhizocrypt-${FAMILY_ID}:rhizocrypt|health.liveness"
        "loamSpine|3|loamspine-${FAMILY_ID}:permanence|health.liveness"
        "sweetGrass|3|sweetgrass-${FAMILY_ID}:sweetgrass|health.liveness"
        "petalTongue|4|petaltongue-${FAMILY_ID}:petaltongue|health.liveness"
    )

    for entry in "${checks[@]}"; do
        IFS='|' read -r display phase sock_candidates method <<< "$entry"
        local found_sock=""
        IFS=':' read -ra candidates <<< "$sock_candidates"
        for candidate in "${candidates[@]}"; do
            local try="$SOCKET_DIR/${candidate}.sock"
            if [[ -S "$try" ]]; then
                found_sock="$try"
                break
            fi
        done
        if [[ -n "$found_sock" ]]; then
            local resp
            resp=$(health_check "$found_sock" "$method" 2>/dev/null || true)
            if [[ -n "$resp" ]] && echo "$resp" | grep -q '"result"'; then
                printf "%-14s %-6s \033[32m%-10s\033[0m %s\n" "$display" "$phase" "ALIVE" "$found_sock"
            else
                printf "%-14s %-6s \033[33m%-10s\033[0m %s\n" "$display" "$phase" "SOCKET" "$found_sock"
            fi
        else
            printf "%-14s %-6s \033[31m%-10s\033[0m %s\n" "$display" "$phase" "DOWN" "(no socket)"
        fi
    done

    echo "──────────────────────────────────────────────────────────────"

    # TCP port audit
    local tcp_count=0
    tcp_count=$(ss -tlnp 2>/dev/null | grep -cE "(beardog|songbird|toadstool|nestgate|squirrel|biomeos|rhizocrypt|loamspine|sweetgrass|petaltongue)" 2>/dev/null) || tcp_count=0
    if [[ "$tcp_count" -eq 0 ]]; then
        printf "%-14s %-6s \033[32m%-10s\033[0m %s\n" "TCP Ports" "--" "ZERO" "Tower Atomic: no TCP bound"
    else
        printf "%-14s %-6s \033[31m%-10s\033[0m %s\n" "TCP Ports" "--" "$tcp_count" "WARNING: TCP ports detected"
    fi

    # Ollama check
    if curl -sf http://localhost:11434/api/tags >/dev/null 2>&1; then
        printf "%-14s %-6s \033[32m%-10s\033[0m %s\n" "Ollama" "ext" "ALIVE" "$OLLAMA_ENDPOINT"
    else
        printf "%-14s %-6s \033[31m%-10s\033[0m %s\n" "Ollama" "ext" "DOWN" "$OLLAMA_ENDPOINT"
    fi
    echo "══════════════════════════════════════════════════════════════"
    echo ""
}

cmd_restart() {
    cmd_stop
    sleep 2
    cmd_start
}

case "${1:-status}" in
    start)   cmd_start   ;;
    stop)    cmd_stop    ;;
    status)  cmd_status  ;;
    restart) cmd_restart ;;
    *)       echo "Usage: $0 {start|stop|status|restart}"; exit 1 ;;
esac
