# plasmidBin — Sovereign Binary Distribution

Public distribution of ecoPrimals musl-static ecoBin binaries.

**Owner**: primalSpring (syntheticChemistry/primalSpring)
**Release**: v2026.05.25 (v5.6.0 — Wave 50, 13/13 primals, 458-method registry, post-primordial)
**License**: AGPL-3.0-or-later

---

## What This Is

plasmidBin is the **binary release channel** for the ecoPrimals sovereign
compute stack. It distributes pre-built, statically-linked, stripped binaries
for all NUCLEUS primals — ready to deploy on any Linux machine without
dependencies.

**primalSpring owns plasmidBin.** It harvests, validates, and releases
binaries. It finds gaps for upstream primal teams and standardizes
compositions for downstream springs.

Some primals have private source repos (bearDog, skunkBat). Their binaries
ship publicly here — stripped static ELF with no debug info. Source will be
public when polished for release.

## Binary Inventory (v5.6.0 — Wave 50 Covalent HPC)

All 13 x86_64 primals: **musl-static, stripped, blake3 verified.**
**13/13 primals ALIVE**, exp094 parity checks PASS. All LD gaps RESOLVED.

### NUCLEUS Atom (9 primals)

| Binary | Atomic | Size | Version | Status |
|--------|--------|------|---------|--------|
| beardog | Tower | 7.3M | 0.9.0 | static, stripped |
| songbird | Tower | 16M | 0.2.1 | static, stripped |
| toadstool | Node | 12M | 0.2.0 | static, stripped, BTSP auto-detect |
| barracuda | Node | 5.2M | 0.4.0 | static, stripped, JSON-RPC + tarpc |
| coralreef | Node | 6.8M | 0.2.0 | static, stripped |
| nestgate | Nest | 8.0M | 0.5.0 | static, stripped |
| rhizocrypt | Nest | 5.9M | 0.14.0 | static, stripped, UDS enabled |
| loamspine | Nest | 5.1M | 0.9.16 | static, stripped, UDS-first |
| sweetgrass | Nest | 11M | 0.7.37 | static, stripped |

### Meta-Tier (3 primals)

| Binary | Size | Version | Status |
|--------|------|---------|--------|
| biomeos | 15M | 0.1.0 | static, stripped |
| squirrel | 6.8M | 0.1.0 | static, stripped |
| petaltongue | 30M | 1.6.6 | static, stripped, --socket + --family-id |

### Defense

| Binary | Size | Version | Status |
|--------|------|---------|--------|
| skunkbat | 2.4M | 0.2.0 | static, stripped |

**Total deployment footprint**: ~127M for the complete sovereign stack.

### aarch64 (Pixel/GrapheneOS/ARM servers)

| Binary | Size | Status |
|--------|------|--------|
| beardog | 5.6M | static, stripped |
| songbird | 13M | static, stripped |
| toadstool | 13M | static, stripped |
| squirrel | 4.9M | static, stripped |
| biomeos | 14M | static, not stripped |

## Quick Start

### Rust CLI (primary — Wave 51)

```bash
git clone https://github.com/ecoPrimals/plasmidBin.git
cd plasmidBin

# Validate metadata (manifest, checksums, sources)
cargo run -p plasmidbin -- validate .

# Fetch all binaries from latest GitHub Release
cargo run -p plasmidbin -- fetch --all

# Health-check installation
cargo run -p plasmidbin -- doctor

# Start a single primal
cargo run -p plasmidbin -- start beardog

# Launch full NUCLEUS composition
cargo run -p plasmidbin -- launch --composition full
```

### Legacy bash scripts (transitional)

The 20 `.sh` scripts at the repo root predate the Rust CLI. CI workflows
are migrating from bash to `plasmidbin` subcommands. The bash scripts
remain operational but are not the primary interface.

```bash
./fetch.sh --all                        # → plasmidbin fetch --all
./doctor.sh                             # → plasmidbin doctor
./validate_composition.sh nucleus       # → plasmidbin validate .
./stage_usb.sh --dest /mnt/usb          # → plasmidbin stage-usb --dest /mnt/usb
./deploy_gate.sh user@host              # → plasmidbin deploy user@host
```

## Architecture

### Three-Org Model

```
ecoPrimals/             — Primals (sovereign infrastructure, mostly public)
syntheticChemistry/     — Springs (science validation, private)
sporeGarden/            — Products (gen4 consumers, public)
```

### NUCLEUS Atomic Model

```
Tower (electron)   = beardog + songbird + skunkbat  (trust boundary)
Node  (proton)     = Tower + toadstool + barracuda + coralreef  (compute)
Nest  (neutron)    = Tower + nestgate + rhizocrypt + loamspine + sweetgrass  (storage)
NUCLEUS (atom)     = Tower + Node + Nest           (9 unique primals)
Meta-tier          = biomeos + squirrel + petaltongue  (orchestration, AI, UI)
```

### Spring Composition Model

Springs are NOT primals. They validate science by composing NUCLEUS primals:

```
Research paper → Python baseline → Rust validation → Primal composition
```

Each spring has a **niche composition** — the primals it needs deployed:

| Spring | Niche Composition | Validate With |
|--------|------------------|---------------|
| hotSpring | NUCLEUS (9 primals) | `niche-hotspring` |
| neuralSpring | Node + Meta (7 primals) | `niche-neuralspring` |
| wetSpring | Full (12 primals) | `niche-wetspring` |
| airSpring | NUCLEUS (9 primals) | `niche-airspring` |
| groundSpring | NUCLEUS (9 primals) | `niche-groundspring` |
| healthSpring | Tower + Nest + Meta (8 primals) | `niche-healthspring` |
| ludoSpring | Node + Meta (8 primals) | `niche-ludospring` |

## Structure

```
plasmidBin/
├── manifest.toml           # Primals, springs, atomics, niches
├── sources.toml            # GitHub repo map for each primal
├── checksums.toml          # Blake3 checksums per binary per arch
├── ports.env               # TCP port defaults + composition definitions
├── doctor.sh               # Health check (prereqs, binaries, checksums, atomics)
├── validate_composition.sh # Validate any composition or spring niche
├── fetch.sh                # Download binaries from GitHub Releases
├── harvest.sh              # Publish local builds → plasmidBin + GitHub Releases
├── deploy_gate.sh          # Deploy to remote Linux machine via SSH
├── deploy_pixel.sh         # Deploy to Pixel/GrapheneOS via ADB
├── bootstrap_gate.sh       # Self-contained bootstrap for fresh machines
├── start_primal.sh         # Unified primal startup (generic flags → per-primal CLI)
├── nucleus_launcher.sh     # Full NUCLEUS startup + Phase 5 registry seeding
├── seed_workflow.sh        # Dark Forest seed lifecycle
├── validate_gate.sh        # Remote gate health check (TCP JSON-RPC)
├── validate_mesh.sh        # Multi-node mesh health + BirdSong exchange
├── stage_usb.sh            # Stage primals for USB / offline (Tier 3)
├── stop_gate.sh            # Stop primals on a gate
├── update.sh               # Check for upstream updates
├── sync.sh                 # Sync local state with plasmidBin releases
├── build-primal.sh         # Build primal from source (CI + local)
├── cell_launcher.sh        # Cell-level launcher (atomic compositions)
├── deploy_membrane.sh      # Membrane VPS provisioning + deployment
├── primals/                # x86_64 binaries (gitignored)
│   └── aarch64/            # aarch64 binaries (gitignored)
└── receipts/               # Harvest receipts
```

## Release Workflow (primalSpring)

primalSpring owns the release cycle:

```bash
# 1. Build all primals from source (musl-static)
./scripts/build_ecosystem_genomeBin.sh --harvest

# 2. Validate the full composition
cd plasmidBin && ./doctor.sh && ./validate_composition.sh full

# 3. Cut a release
./harvest.sh --release v2026.05.23
```

### NUCLEUS Launcher — Full Composition Startup

`nucleus_launcher.sh` starts primals in dependency order, waits for health,
then seeds Songbird's registry (Phase 5) so springs can discover capabilities:

```bash
# Start a full NUCLEUS with registry seeding
./nucleus_launcher.sh --family-id abc123 --composition nucleus

# Start NUCLEUS + Meta-Tier (12 primals)
./nucleus_launcher.sh --family-id abc123 --composition full --dark-forest

# Re-seed the registry without restarting primals
./nucleus_launcher.sh --family-id abc123 --seed-only

# Springs discover capabilities programmatically after seeding:
curl -s http://127.0.0.1:9200/rpc \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"ipc.resolve","params":{"capability":"tensor"},"id":1}'
```

### What primalSpring validates before release

- All primals build as musl-static (`cargo build --target x86_64-unknown-linux-musl`)
- All binaries are stripped and static ELF
- All blake3 checksums match
- All atomic compositions validate (Tower, Node, Nest, NUCLEUS, Meta)
- All spring niche compositions have required primals present
- **exp094** composition parity: 19/19 PASS (Tower, Node, Nest, Cross-Atomic)

### Finding gaps for upstream

When primalSpring discovers issues during harvest/validation:

1. **Binary gaps** — primal doesn't build musl-static → report to primal team
2. **Checksum drift** — binary changed without version bump → coordinate
3. **Composition gaps** — missing capabilities for a niche → propose wire to primal team
4. **ecoBin violations** — dynamic linking, C deps → file issue upstream

## ecoBin Standard

All binaries must pass:

- **Static ELF** — musl-linked, no dynamic dependencies
- **Stripped** — no debug info (`strip -s` or `[profile.release] strip = true`)
- **Checksummed** — blake3 hash in `checksums.toml`
- **Zero C deps** — no openssl, no ring, no libc in application code
- **Named simply** — `primals/{name}` (x86_64) or `primals/aarch64/{name}`

### Quick self-check for primal teams

```bash
cargo build --release --target x86_64-unknown-linux-musl
file target/x86_64-unknown-linux-musl/release/YOUR_PRIMAL
# Should say: "statically linked" and NOT "not stripped"
b3sum --no-names target/x86_64-unknown-linux-musl/release/YOUR_PRIMAL
```

## Transport

All 13 primals now support UDS. TCP is fallback for cross-gate only.

1. **Unix sockets** (Linux) — `$XDG_RUNTIME_DIR/biomeos/<primal>-{family}.sock`
2. **Abstract sockets** (Android) — `@primal_name`
3. **TCP** (cross-gate, ADB) — ports in `ports.env`

As of Phase 40, all primals bind UDS sockets at standard paths:
- barraCuda: `math-{family}.sock` (symlinked from `barracuda-{family}.sock`)
- rhizoCrypt: `rhizocrypt-{family}.sock` (UDS enabled since S37)
- loamSpine: UDS-first, TCP opt-in via `--listen`
- petalTongue: UDS via `--socket` CLI flag

## Private Source, Public Binary

bearDog and skunkBat have private source repos. Their binaries ship publicly
via plasmidBin GitHub Releases — stripped static ELF with zero debug info.
The binary distribution model means anyone can deploy the full NUCLEUS
stack today. Source repos will go public when the teams are ready.

---

**License**: AGPL-3.0-or-later
