# plasmidBin — Sovereign Binary Distribution (genomeBin Depot)

Full cross-architecture binary depot for the ecoPrimals sovereign compute stack.

**Owner**: primalSpring (syntheticChemistry/primalSpring)
**Release**: v2026.04.21 (Phase 45b — genomeBin v5.1, 46 binaries, capability symlink automation, petalTongue `live` mode)
**License**: AGPL-3.0-or-later

---

## What This Is

plasmidBin is the **genomeBin-compliant binary depot** for the ecoPrimals ecosystem.
It distributes pre-built, statically-linked, stripped binaries for all NUCLEUS primals
across every plausible Rust target — ready to deploy on Linux (x86_64, ARM64, ARMv7,
RISC-V), Windows, Android, and validated for macOS (cargo check, no osxcross).

**46 binaries shipped across 6 target triples.**

Layout: `primals/{target-triple}/{binary}` (genomeBin standard)
Legacy symlinks: `primals/{binary}` -> `x86_64-unknown-linux-musl/{binary}`

## Target Matrix (ecoBin Architecture Standard v3.0)

| Target Triple | Tier | Linker | Primals | Status |
|---------------|------|--------|---------|--------|
| x86_64-unknown-linux-musl | Tier 1 MUST | musl-tools | 13/14 | Full |
| aarch64-unknown-linux-musl | Tier 1 MUST | aarch64-linux-gnu-gcc | 12/14 | Full |
| armv7-unknown-linux-musleabihf | Tier 1 MUST | arm-linux-gnueabihf-gcc | 10/14 | Full |
| x86_64-pc-windows-gnu | Tier 2 SHOULD | x86_64-w64-mingw32-gcc | 1 (barraCuda) | Partial |
| aarch64-linux-android | Tier 2 SHOULD | NDK clang | 5 | Partial |
| riscv64gc-unknown-linux-musl | Tier 3 NICE | riscv64-linux-gnu-gcc | 1 (primalspring) | Check+Link |
| x86_64-apple-darwin | Tier 2 SHOULD | (check-only) | 8 check-pass | Check Only |
| aarch64-apple-darwin | Tier 2 SHOULD | (check-only) | 8 check-pass | Check Only |

### Per-Primal Coverage

| Primal | x86_64-musl | aarch64-musl | armv7-musl | windows | android | riscv64 |
|--------|-------------|--------------|------------|---------|---------|---------|
| beardog | FULL | FULL | FULL | - | - | check |
| songbird | FULL | FULL | FULL | - | FULL | check |
| nestgate | FULL | lib-only | lib-only | - | lib-only | check |
| toadstool | FULL | FULL | 32bit-ovf | - | - | check |
| squirrel | FULL | FULL | FULL | - | - | check |
| biomeos | FULL | FULL | 32bit-ovf | - | lib-only | check |
| barracuda | FULL | FULL | FULL | FULL | FULL | check |
| coralreef | FULL | FULL | FULL | - | - | check |
| rhizocrypt | FULL | FULL | FULL | - | FULL | check |
| loamspine | FULL | FULL | FULL | - | FULL | check |
| sweetgrass | FULL | FULL | FULL | - | FULL | check |
| petaltongue | FULL | FULL | FULL | - | - | check |
| skunkbat | lib-only | lib-only | lib-only | - | lib-only | lib-only |
| primalspring_primal | FULL | FULL | FULL | - | - | FULL |

### Documented Gaps

- **nestgate/skunkbat**: Library-only crates — no binary target produced (workspace structure)
- **toadstool on armv7**: 32-bit usize overflow in GPU allocation constant (4GB > u32::MAX)
- **biomeos on armv7**: 32-bit usize overflow in cast.rs (1 << 53 overflows on 32-bit)
- **macOS**: cargo check passes for 8/14 primals (proves pure Rust), no osxcross for linking
- **RISC-V**: All primals cargo-check pass, musl sysroot incomplete for linking most primals

## Quick Start

### Build from source (full target matrix)

```bash
# Build Tier 1 MUST targets (Linux x86_64 + aarch64 + armv7)
./scripts/build_ecosystem_genomeBin.sh --tier1

# Build all tiers
./scripts/build_ecosystem_genomeBin.sh --all

# Build + harvest into plasmidBin
./scripts/build_ecosystem_genomeBin.sh --tier1 --harvest

# Build a single target
./scripts/build_ecosystem_genomeBin.sh --target aarch64-linux-android
```

### Fetch binaries (consumer)

```bash
git clone https://github.com/ecoPrimals/plasmidBin.git
cd plasmidBin
./fetch.sh --all           # Fetch all binaries from latest GitHub Release
./fetch.sh --primal beardog # Fetch a single primal
./doctor.sh                # Verify installation
```

### Validate a composition

```bash
./validate_composition.sh nucleus          # NUCLEUS atom (9 primals)
./validate_composition.sh niche-hotspring  # What hotSpring needs
./validate_composition.sh full             # Full stack (12+ primals)
```

### Deploy a Cell (Recommended — Cold-Start from plasmidBin)

Cell graphs define complete primal compositions for a domain. No primalSpring
source needed — everything lives in plasmidBin.

```bash
# Clone plasmidBin on any Linux machine
git clone https://github.com/ecoPrimals/plasmidBin.git
cd plasmidBin

# See available cells
./cell_launcher.sh list

# Deploy ludoSpring (game science — 12 primals, petalTongue live)
./cell_launcher.sh ludospring start

# Deploy esotericWebb (CRPG garden — 11 primals)
./cell_launcher.sh esotericwebb start

# Check health
./cell_launcher.sh ludospring status

# Stop
./cell_launcher.sh ludospring stop

# Dry-run (show plan without starting)
./cell_launcher.sh ludospring start --dry-run

# Override family identity and seed
FAMILY_ID=myteam BEARDOG_FAMILY_SEED=$(head -c 32 /dev/urandom | xxd -p) \
  ./cell_launcher.sh ludospring start
```

Cell graphs live in `cells/`. Primals start in dependency order via
`start_primal.sh`, which auto-detects your architecture. BTSP seeds are
auto-generated from `/dev/urandom` if not provided.

### Deploy Individual Primals

```bash
# Local machine (auto-detects target triple)
./start_primal.sh beardog --tcp-port 9100

# Remote gate via SSH
./deploy_gate.sh friend@192.168.1.42 --composition full

# Pixel/GrapheneOS via ADB (uses aarch64-unknown-linux-musl binaries)
./deploy_pixel.sh --composition tower --dark-forest

# benchScale Docker lab
cd ../benchScale && ./scripts/deploy-ecoprimals.sh --lab my-lab --plasmidbin /path/to/plasmidBin
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
Tower (electron)   = beardog + songbird           (trust boundary)
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
| ludoSpring | Full + Meta (12 primals, **pure composition**) | `cell_launcher.sh ludospring` |
| esotericWebb | Full + Meta (11 primals, **pure composition**) | `cell_launcher.sh esotericwebb` |

### Cell Deployment (Pure Composition)

Springs that have reached the **pure composition** stage deploy entirely through
primal composition — no spring binary at all. The cell graph defines the primal
topology; domain science is served by existing primals (barraCuda for math,
petalTongue for UI, provenance trio for sessions).

Cell graphs: `cells/*.toml`
Launcher: `cell_launcher.sh`

## Structure

```
plasmidBin/
├── manifest.toml           # Primals, springs, atomics, niches
├── sources.toml            # GitHub repo map for each primal
├── checksums.toml          # Blake3 checksums per binary per arch
├── ports.env               # TCP port defaults + composition definitions
├── cell_launcher.sh        # Deploy a cell graph (cold-start, portable)
├── cells/                  # Cell graphs for spring/garden compositions
├── doctor.sh               # Health check (prereqs, binaries, checksums, atomics)
├── validate_composition.sh # Validate any composition or spring niche
├── fetch.sh                # Download binaries from GitHub Releases
├── harvest.sh              # Publish local builds → plasmidBin + GitHub Releases
├── deploy_gate.sh          # Deploy to remote Linux machine via SSH
├── deploy_pixel.sh         # Deploy to Pixel/GrapheneOS via ADB
├── bootstrap_gate.sh       # Self-contained bootstrap for fresh machines
├── start_primal.sh         # Unified primal startup (generic flags → per-primal CLI)
├── seed_workflow.sh        # Dark Forest seed lifecycle
├── validate_gate.sh        # Remote gate health check (TCP JSON-RPC)
├── validate_mesh.sh        # Multi-node mesh health + BirdSong exchange
├── stop_gate.sh            # Stop primals on a gate
├── update.sh               # Check for upstream updates
├── primals/                # x86_64 binaries (gitignored)
│   └── aarch64/            # aarch64 binaries (gitignored)
└── receipts/               # Harvest receipts
```

## Release Workflow (primalSpring)

primalSpring owns the release cycle:

```bash
# 1. Build all primals from source (musl-static)
./scripts/build_ecosystem_musl.sh --harvest

# 2. Validate the full composition
cd plasmidBin && ./doctor.sh && ./validate_composition.sh full

# 3. Cut a release
./harvest.sh --release v2026.04.11
```

### What primalSpring validates before release

- All primals build as musl-static (`cargo build --target x86_64-unknown-linux-musl`)
- All binaries are stripped and static ELF
- All blake3 checksums match
- All atomic compositions validate (Tower, Node, Nest, NUCLEUS, Meta)
- All spring niche compositions have required primals present

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

## Interactive Compositions (petalTongue `live` Mode)

petalTongue supports a `live` subcommand that runs the IPC server and native
egui window in the same process, sharing `VisualizationState`. This enables
interactive garden products where primals push `visualization.render.scene`
over UDS and the native GPU-accelerated window renders in real time.

```bash
# Launch petalTongue in live mode
petaltongue live --socket $XDG_RUNTIME_DIR/biomeos/petaltongue-myfamily.sock

# Deploy graphs set mode = "live" for the petaltongue node
# See: infra/wateringHole/LIVE_GUI_COMPOSITION_PATTERN.md
```

## Transport

Primals use Unix sockets by default. TCP is fallback only.

1. **Unix sockets** (Linux) — `$XDG_RUNTIME_DIR/biomeos/<primal>.sock`
2. **Abstract sockets** (Android) — `@primal_name`
3. **TCP** (cross-gate, ADB) — ports in `ports.env`

## Private Source, Public Binary

bearDog and skunkBat have private source repos. Their binaries ship publicly
via plasmidBin GitHub Releases — stripped static ELF with zero debug info.
The binary distribution model means anyone can deploy the full NUCLEUS
stack today. Source repos will go public when the teams are ready.

---

**License**: AGPL-3.0-or-later
