# Context — plasmidBin

## What This Is

plasmidBin is the binary distribution surface for the ecoPrimals sovereign
computing ecosystem. It distributes pre-built primal binaries (ecoBins and
genomeBins) so that any machine — development workstation, family tower,
university lab, Docker container — can run primal compositions without
building from source.

Metadata and scripts live in git. Binaries live in GitHub Releases.

## Role in the Ecosystem

plasmidBin sits between spring development (where primals are built) and gate
deployment (where primals run). Springs produce binaries; plasmidBin distributes
them; gates consume them. This separation means consumers never depend on
spring source code — they discover primal capabilities at runtime via JSON-RPC.

The repository is public so that anyone can clone it, run `plasmidbin fetch`
to pull binaries from GitHub Releases, and start compositions with
`plasmidbin launch`.

## Technical Facts

- **Language:** Rust 2024 (`plasmidbin` CLI — 15 subcommands replacing all bash scripts), TOML (metadata)
- **License:** AGPL-3.0-or-later
- **Binary format:** musl-static ELF, stripped, cross-compiled (x86_64, aarch64, armv7)
- **Integrity:** BLAKE3 checksums in `checksums.toml`, verified natively by `plasmidbin` (blake3 crate)
- **Primals tracked:** 13 (beardog, songbird, nestgate, toadstool, squirrel,
  biomeos, petaltongue, rhizocrypt, loamspine, sweetgrass, coralreef,
  barracuda, skunkbat)
- **Springs tracked:** 8 (primalspring, hotspring, healthspring, wetspring,
  neuralspring, ludospring, groundspring, airspring)

## Key Files

| File | Purpose |
|------|---------|
| `crates/plasmidbin/` | Unified CLI binary — 15 subcommands (validate, harvest, fetch, doctor, ...) |
| `crates/plasmidbin-types/` | Typed domain models — Arch enum, serde-typed TOML parsing |
| `ports.env` | Canonical TCP port assignments (9100–9800) and composition definitions |
| `manifest.toml` | Ecosystem genome: primals, springs, atomics, niches, binaries |
| `checksums.toml` | BLAKE3 hashes per primal per target triple |
| `sources.toml` | Maps primals to source repos with build metadata |
| `*.sh` (repo root) | 20 legacy bash scripts — transitional, being replaced by plasmidbin CLI |

## How It Works

```
Developer gate                    Consumer gate / lab / Docker
─────────────                     ─────────────────────────────
cargo build --release             git clone ecoPrimals/plasmidBin
cp binary → plasmidBin/<name>/    cd plasmidBin
plasmidbin harvest                plasmidbin fetch --all
  └─ creates GitHub Release         └─ downloads + verifies binaries
     with all binaries             plasmidbin launch --composition full
                                     └─ starts beardog, songbird, biomeos, ...
```

## Composition Definitions

plasmidBin defines standard compositions in `ports.env`:

- **Tower:** beardog + songbird + skunkbat (trust boundary)
- **Compute:** tower + toadstool (+ hardware orchestration)
- **Node:** compute + squirrel (+ AI coordination)
- **Nest:** tower + nestgate (+ sovereign storage)
- **Full NUCLEUS:** all primals + biomeos + petaltongue
- **Storytelling:** beardog + songbird + biomeos + squirrel + petaltongue

## USB / Offline Staging (Tier 3)

`plasmidbin stage-usb` exports a self-contained directory of primal binaries and
metadata for offline deployment. This enables lithoSpore Tier 3 USB
artifacts (full NUCLEUS composition without network access) and offline
gate bootstrapping.

The output follows the canonical genomeBin layout (`primals/<full-triple>/`)
with `manifest.toml`, `checksums.toml`, `ports.env`, and a `VERSION` file
containing staging provenance (commit, timestamp, arch, composition).

lithoSpore's `resolve_binary()` detects the USB layout and resolves primal
paths accordingly.

## What This Does NOT Do

- Does not build primals from source (that's each primal's own repo)
- Does not orchestrate running compositions (that's biomeOS)
- Does not manage deploy graphs or topology (that's primalSpring + benchScale)
- Does not handle seed distribution or genetic trust (that's bearDog + songBird)

## Related Repositories

- [wateringHole](https://github.com/ecoPrimals/wateringHole) — ecosystem
  standards, primal registry, architecture guidance
- [barraCuda](https://github.com/ecoPrimals/barraCuda) — GPU math engine
  (public, source available)
- [toadStool](https://github.com/ecoPrimals/toadStool) — hardware discovery
  (public, source available)
- [primalSpring](https://github.com/syntheticChemistry/primalSpring) —
  composition validation experiments

## CI/CD Architecture — Sole Paid Hub

plasmidBin is the **only repository in the ecoPrimals ecosystem with paid
GitHub Actions minutes**. All other primal repositories use free-tier runners
for lint and test, and dispatch to plasmidBin for cross-architecture binary
builds and release publishing.

### How the Pipeline Works

```
Primal repo (push to main)
  └─ ci.yml (free-tier: clippy, test, fmt)
  └─ notify-plasmidbin.yml
       └─ repository_dispatch → ecoPrimals/plasmidBin
            └─ auto-harvest.yml (paid runners)
                 ├─ build job (3× parallel matrix: x86_64, aarch64, armv7)
                 │   concurrency: auto-harvest-{primal}
                 │   (per-primal — multiple primals build in parallel)
                 └─ consolidate job
                     concurrency: harvest-consolidate
                     (serialized — one push at a time, with rebase retry)
                     ├─ harvest artifacts
                     ├─ commit checksums.toml
                     ├─ push with 3-attempt rebase retry
                     └─ upload to GitHub Release (clobber existing assets)
```

### Cost Model

| Repo | Runner | Minutes | Triggers |
|------|--------|---------|----------|
| Primal repos (×13) | `ubuntu-latest` (free) | ~2 min / push | push to main |
| plasmidBin | `ubuntu-latest` (paid) | ~15 min / primal (3 arch × 5 min) | dispatch, manual, weekly sweep |

Only plasmidBin incurs paid Actions minutes. A single primal dispatch costs
~15 minutes (3-arch matrix build). A full weekly sweep costs ~195 minutes
(13 primals × 15 min). Per-primal concurrency groups prevent redundant builds
while allowing independent primals to build in parallel.

### Per-Primal Concurrency (Shipped May 2026)

The `auto-harvest.yml` workflow uses per-primal concurrency groups:

- `auto-harvest-{primal}` for build jobs — if beardog and songbird dispatch
  simultaneously, both build in parallel. If beardog dispatches twice before
  the first finishes, the second waits (no cancellation).
- `harvest-consolidate` for the consolidate/push job — serialized to prevent
  git conflicts when multiple primals finish builds simultaneously. A 3-attempt
  rebase retry loop handles races against the `plasmidBin-bot` committer.

### Primal CI (Stays Free-Tier)

Each primal repo has:

- `ci.yml` — `cargo clippy`, `cargo test`, `cargo fmt --check` on
  `ubuntu-latest` (free). No binary output.
- `notify-plasmidbin.yml` — sends `repository_dispatch` to plasmidBin on
  push to `main`. Payload: `{ "primal": "{name}", "sha": "{commit}" }`.

No primal repo builds cross-architecture binaries or uploads releases. That
is entirely plasmidBin's job.

## Future Distribution Channels

Today, `plasmidbin fetch` downloads from GitHub Releases using the
`{binary}-{triple}` asset naming convention. The `mirror_url` field in
`manifest.toml` is the extensibility point for additional channels.

### Planned Channels

| Channel | Status | Asset Format | Consumer |
|---------|--------|-------------|----------|
| GitHub Releases | **Current, primary** | `{binary}-{triple}` | `plasmidbin fetch` |
| Self-hosted CDN | Planned — uncomment `mirror_url` | Same naming | `plasmidbin fetch --mirror` |
| OCI registry | Planned | Binary layers, OCI image manifest | `docker pull`, `crane` |
| apt/deb repository | Planned | `.deb` packages per primal | `apt install beardog` |
| Nix flake | Planned | Nix derivation per primal | `nix run ecoPrimals#beardog` |

**CDN (`bins.ecoprimals.dev`)**: The `mirror_url` field in `manifest.toml` is
already reserved. When active, `plasmidbin fetch` will try the mirror first
and fall back to GitHub Releases. CDN can be any static file host (S3, Cloudflare R2,
self-hosted nginx) serving the same `{binary}-{triple}` naming.

**OCI Registry**: Package each primal as a single-layer OCI image. Enables
container-native deploys (`docker run --rm ecoPrimals/beardog:latest`) and
integrates with existing container orchestration (Kubernetes, Podman).

**apt/deb**: Debian packages with systemd unit files. Each primal becomes
`sudo apt install ecoPrimals-beardog`. Requires a signed apt repository
(GPG or ed25519, see signing roadmap below).

**Nix Flake**: A `flake.nix` that fetches binaries from GitHub Releases
and wraps them as Nix derivations. Enables reproducible NixOS deployments
(`nix run github:ecoPrimals/plasmidBin#beardog`).

### Fetch Contract

Any new distribution channel MUST produce:

1. The same `{binary}-{triple}` asset naming convention
2. Verifiable integrity against `checksums.toml` (BLAKE3)
3. A mechanism for `plasmidbin fetch` to discover and prefer the channel

`plasmidbin fetch` is the consumer interface. It checks `manifest.toml` for
`mirror_url`, falls back to GitHub Releases, and always verifies BLAKE3
checksums after download.

## Signing Roadmap

| Phase | What | When |
|-------|------|------|
| **Current** | BLAKE3 checksums in `checksums.toml` | Shipped |
| **Phase 1** | Ed25519 detached signatures per binary | When apt/OCI channels ship |
| **Phase 2** | BearDog-derived signing keys | When BearDog key export is ecosystem-stable |
| **Phase 3** | Signed `checksums.toml` manifest (Sigstore-compatible) | When Phase 2 is live |

**Phase 1**: Each binary gets a `.sig` file containing an ed25519 signature.
The signing key lives in GitHub Actions secrets. `plasmidbin fetch` verifies
signatures when present, warns when absent.

**Phase 2**: BearDog already provides `crypto.generate_keypair` and
`crypto.sign`. When BearDog's key material export is stable across the
ecosystem, the signing key migrates from a static secret to a BearDog-derived
key. This aligns binary integrity with the BTSP trust chain.

**Phase 3**: The entire `checksums.toml` gets a signed manifest (compatible
with Sigstore's transparency log). Consumers can verify the full release
integrity with a single signature check.

## Design Philosophy

Primals are sovereign organisms. Each is a self-contained Rust binary that
knows only itself and discovers others at runtime. plasmidBin is the transport
medium — like a plasmid carrying genetic material between organisms, it moves
compiled capabilities between machines without creating compile-time coupling.

The binary distribution model enables a wave release strategy: primal source
repos go public gradually as they pass audit milestones, while binaries are
available to all consumers immediately through plasmidBin.
