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

The repository is public so that anyone can clone it, run `./fetch.sh` to pull
binaries from GitHub Releases, and start compositions with `./start_primal.sh`.

## Technical Facts

- **Language:** Bash (scripts), TOML (metadata)
- **License:** AGPL-3.0-or-later (scripts). Individual binaries carry their own
  license metadata in `metadata.toml`.
- **Binary format:** musl-static ELF, PIE-enabled, x86_64-linux (aarch64 planned)
- **Integrity:** SHA-256 checksums in `metadata.toml`, verified by `fetch.sh`
- **Primals tracked:** 11 (beardog, songbird, nestgate, toadstool, squirrel,
  biomeos, rhizocrypt, loamspine, sweetgrass, petaltongue, coralreef)
- **Springs tracked:** 6 (ludospring, groundspring, healthspring, neuralspring,
  wetspring, primalspring)

## Key Files

| File | Purpose |
|------|---------|
| `fetch.sh` | Download binaries from GitHub Releases, verify checksums |
| `harvest.sh` | Build checksums, update metadata, create GitHub Release |
| `start_primal.sh` | Unified startup wrapper — maps generic flags to per-primal CLI quirks |
| `ports.env` | Canonical TCP port assignments (9100–9800) and composition definitions |
| `manifest.lock` | Resolved versions for current deployment |
| `*/metadata.toml` | Per-primal version, capabilities, provenance, checksum |

## How It Works

```
Developer gate                    Consumer gate / lab / Docker
─────────────                     ─────────────────────────────
cargo build --release             git clone ecoPrimals/plasmidBin
cp binary → plasmidBin/<name>/    cd plasmidBin
./harvest.sh                      ./fetch.sh
  └─ creates GitHub Release         └─ downloads + verifies binaries
     with all binaries               source ports.env
                                     ./start_primal.sh beardog
                                     ./start_primal.sh songbird
                                     ./start_primal.sh biomeos
```

## Composition Definitions

plasmidBin defines standard compositions in `ports.env`:

- **Tower:** beardog + songbird (security + networking foundation)
- **Compute:** tower + toadstool (+ hardware orchestration)
- **Node:** compute + squirrel (+ AI coordination)
- **Nest:** tower + nestgate (+ sovereign storage)
- **Full NUCLEUS:** all primals + biomeos + petaltongue
- **Storytelling:** beardog + songbird + biomeos + squirrel + petaltongue

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

## Design Philosophy

Primals are sovereign organisms. Each is a self-contained Rust binary that
knows only itself and discovers others at runtime. plasmidBin is the transport
medium — like a plasmid carrying genetic material between organisms, it moves
compiled capabilities between machines without creating compile-time coupling.

The binary distribution model enables a wave release strategy: primal source
repos go public gradually as they pass audit milestones, while binaries are
available to all consumers immediately through plasmidBin.
