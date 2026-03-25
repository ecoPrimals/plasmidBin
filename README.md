<!--
SPDX-License-Identifier: AGPL-3.0-or-later
Documentation: CC-BY-SA-4.0
-->

# plasmidBin — Primal Deployment Surface

**Purpose**: Central distribution surface for deployable primal binaries
(genomeBins and ecoBins). All consumers — springs, subprojects, and
cross-evolution substrates like Esoteric Webb — resolve primals from here,
not from spring source trees.

---

## Why plasmidBin exists

Springs are development workspaces. They contain science, experiments,
specs, and source code. But springs are NOT primals — they PRODUCE primals.

The boundary is:

```
Spring (development)  →  builds  →  genomeBin/ecoBin (artifact)
                                          ↓
                                    plasmidBin/ (deployment surface)
                                          ↓
                              Consumer discovers + launches
                         (biomeOS, primalSpring, Esoteric Webb, etc.)
```

This separation ensures:

1. **Functionally independent evolution** — a spring can refactor, rename
   crates, or restructure without breaking any consumer. The consumer only
   knows the primal's IPC capabilities, not its source layout.

2. **No cross-spring compile dependencies** — consumers never `cargo add`
   a spring crate. They discover primal binaries at runtime via Songbird
   or filesystem probing.

3. **Reproducible deployments** — a plasmidBin entry is a versioned,
   checksummed, PIE-verified binary. The same artifact deploys everywhere.

4. **Lean consumers** — Esoteric Webb, BYOB niches, and other compositions
   are lighter than springs because they consume compiled capabilities,
   not source-level science.

---

## Relationship to wateringHole/genomeBin/

The `wateringHole/genomeBin/manifest.toml` is the **registry** — it defines
what primal binaries exist, their versions, architectures, capabilities,
and ecoBin grades.

`plasmidBin/` is the **local deployment cache** — where actual binaries
land for a given machine or niche. Think of it as `node_modules` for
primals: the manifest says what exists; plasmidBin holds what's deployed.

```
wateringHole/genomeBin/manifest.toml   →  "what is available"
plasmidBin/                             →  "what is deployed here"
```

---

## Directory structure

```
plasmidBin/
  README.md              This file
  manifest.lock          Resolved versions for current deployment (generated)
  beardog/               BearDog primal binary + metadata
    beardog              The genomeBin binary
    metadata.toml        Version, checksum, capabilities, ecoBin grade
  songbird/              Songbird primal binary + metadata
  squirrel/              Squirrel AI primal binary + metadata
  rhizocrypt/            rhizoCrypt primal binary + metadata
  loamspine/             loamSpine primal binary + metadata
  sweetgrass/            sweetGrass primal binary + metadata
  biomeos/               biomeOS orchestrator binary + metadata
  toadstool/             ToadStool compute primal binary + metadata
  barracuda/             barraCuda GPU primal binary + metadata
  coralreef/             coralReef shader compiler binary + metadata
  nestgate/              NestGate storage primal binary + metadata
  petaltongue/           petalTongue visualization primal binary + metadata
  ludospring/            ludoSpring game science primal binary + metadata
```

Each subdirectory is optional — deploy only the primals your niche needs.
Capability-based discovery handles absent primals via graceful degradation.

---

## metadata.toml format

Each primal directory contains a `metadata.toml`:

```toml
[primal]
name = "beardog"
version = "0.9.0"
architecture = "x86_64-linux"
checksum_blake3 = "abc123..."
pie_verified = true
ecobin_grade = "A++"

[capabilities]
domains = ["crypto", "birdsong", "lineage"]
methods = ["crypto.sign", "crypto.hash", "crypto.verify"]

[provenance]
built_from = "ecoSprings/towerSpring"
built_at = "2026-03-20T14:00:00Z"
```

The `built_from` field is a **derivation reference** — it records which
spring produced the binary, but creates no runtime dependency on that
spring's source tree.

---

## How consumers use plasmidBin

### biomeOS / primalSpring

Deploy graphs reference primal names. biomeOS resolves them from plasmidBin
(or fetches from NestGate if not locally cached):

```toml
[nodes.beardog]
binary = "plasmidBin/beardog/beardog"
capabilities = ["crypto.sign", "crypto.hash"]
```

### Esoteric Webb

Webb's BYOB niche discovers primals via:
1. Songbird `discovery.query` (network)
2. Filesystem probe of `plasmidBin/` (local)
3. XDG/biomeOS socket directories (convention)

Webb never imports a spring crate. It talks to primal binaries over
JSON-RPC IPC.

### Other springs

Springs that need primal capabilities at test time (e.g. ludoSpring
testing against a live Squirrel) can launch primals from plasmidBin in
their integration test harness, maintaining source-level independence.

---

## Public distribution via GitHub Releases

This repository is public at
[github.com/ecoPrimals/plasmidBin](https://github.com/ecoPrimals/plasmidBin).

**Metadata lives in git. Binaries live in GitHub Releases.**

- `metadata.toml`, `manifest.lock`, scripts, and docs are tracked in git.
- Compiled primal binaries are attached as **release assets** on tagged
  GitHub Releases (e.g. `v2026.03.24`).
- Binaries are excluded from git via `.gitignore` — the repo stays small,
  and every clone is fast.

This decouples binary availability from source publication. Primal source
repos can evolve privately while consumers get stable, pinned binaries.

---

## Populating plasmidBin (harvest)

The maintainer runs `./harvest.sh` after building new primal binaries:

```bash
# 1. Build the primal from its (private) source tree
cd /path/to/phase2/rhizoCrypt
cargo build --release

# 2. Copy binary to plasmidBin
cp target/release/rhizocrypt /path/to/plasmidBin/rhizocrypt/

# 3. Run harvest — updates checksums, manifest, creates release
cd /path/to/plasmidBin
./harvest.sh
```

`harvest.sh` computes checksums, updates `metadata.toml` and
`manifest.lock`, creates a GitHub Release, and attaches all binaries.

See `harvest.sh --help` for options.

### Manual harvest (without the script)

```bash
# Update checksum in metadata.toml
sha256sum rhizocrypt/rhizocrypt
# Edit rhizocrypt/metadata.toml with new checksum

# Commit metadata
git add rhizocrypt/metadata.toml manifest.lock
git commit -m "harvest: rhizocrypt 0.14.1"
git push

# Create release with binary
gh release create v2026.03.25 \
  rhizocrypt/rhizocrypt \
  --title "rhizocrypt 0.14.1" \
  --notes "Updated rhizocrypt to 0.14.1"
```

---

## Fetching primals

Consumers run `./fetch.sh` to download primal binaries:

```bash
git clone git@github.com:ecoPrimals/plasmidBin.git
cd plasmidBin
./fetch.sh
```

`fetch.sh` reads `manifest.lock`, downloads binaries from the latest
GitHub Release, verifies checksums, and makes them executable.

### Manual fetch (without the script)

```bash
# Download all binaries from latest release
gh release download --repo ecoPrimals/plasmidBin --pattern '*' --dir /tmp/plasmidbins

# Move to correct directories
mv /tmp/plasmidbins/rhizocrypt rhizocrypt/
mv /tmp/plasmidbins/loamspine loamspine/
mv /tmp/plasmidbins/sweetgrass sweetgrass/

# Verify and make executable
sha256sum -c <(grep checksum_sha256 */metadata.toml | ...)
chmod +x */rhizocrypt */loamspine */sweetgrass
```

### Environment override

For non-standard layouts, consumers can set:

```bash
export ECOPRIMALS_PLASMID_BIN=/path/to/plasmidBin
```

Webb and other consumers check this variable first before relative paths.

---

## License

AGPL-3.0-or-later (tooling). Individual primal binaries carry their own
license metadata in `metadata.toml`. See `SOURCE_AVAILABILITY.md` for
AGPL compliance details regarding binary distribution.
