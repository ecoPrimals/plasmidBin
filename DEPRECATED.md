# plasmidBin Shell Scripts — DEPRECATED (Wave 157h)

All shell scripts in this directory have been superseded by native `membrane` CLI commands.
The scripts have been moved to `infra/fossilRecord/plasmidBin-wave157h/` for reference.

## Migration Map

Use this table to find the `membrane` equivalent for any script you were using.

| Former Script | membrane CLI Equivalent | Notes |
|---|---|---|
| `bootstrap_gate.sh` | `membrane gate.bootstrap` | Full gate bootstrap lifecycle |
| `build-primal.sh` | `membrane plasmid.build` | Clone + build + stage single primal |
| `cell_launcher.sh` | biomeOS composition graphs | Superseded by biomeOS NUCLEUS orchestration |
| `deploy_gate.sh` | `membrane gate.deploy` | Remote gate binary deployment |
| `deploy_pixel.sh` | `membrane gate.deploy --target android` | ADB deploy to Pixel/GrapheneOS |
| `doctor.sh` | `membrane health.audit` + `membrane plasmid.staleness` | Depot health and compliance |
| `fetch.sh` | `membrane plasmid.fetch` | Download binaries from depot |
| `gate-usb-bootstrap.sh` | `membrane gate.enroll` | USB gate bootstrap (now manifest-driven) |
| `nucleus_launcher.sh` | `membrane-nucleus.target` (systemd) | NUCLEUS target replaces manual launcher |
| `onboard-gate-relay.sh` | `membrane gate.relay` | Pull relay config to gate |
| `seed_workflow.sh` | `membrane gate.seed` | Beacon + lineage seed lifecycle |
| `stage_usb.sh` | `membrane plasmid.push --target usb` | Stage binaries for offline deploy |
| `start_primal.sh` | `membrane gate.service.restart <primal>` | Unified primal startup |
| `stop_gate.sh` | `systemctl stop membrane-nucleus.target` | Native systemd |
| `sync.sh` | `membrane plasmid.depot_sync` | Post-pull checksum re-fetch |
| `update.sh` | `membrane plasmid.refresh` | Fetch latest binaries |
| `validate_composition.sh` | `membrane plasmid.composition` | Composition manifest validation |
| `validate_gate.sh` | `membrane gate.validate` | Remote TCP JSON-RPC health probes |
| `validate_mesh.sh` | `membrane gate.health --mesh` | Multi-node mesh health matrix |
| `enroll/gate-enroll.sh` | `membrane gate.enroll` | Self-enrollment via Forgejo RPC |
| `enroll/enroll-fleet.sh` | `membrane gate.enroll --fleet` | Fleet enrollment wrapper |
| `membrane/share_credentials.sh` | `membrane credentials.*` | age encrypt/decrypt credentials |

## What remains in this directory

- `DEPRECATED.md` — this file
- `enroll/hub-peer.conf` — WireGuard hub peer config template
- `profiles/` — gate profile configs (still consumed by membrane)
- `templates/` — systemd unit templates (still consumed by membrane)
- `primals/` — symlink to canonical depot path
- `Cargo.toml`, `Cargo.lock`, `crates/` — Rust workspace (nucleus_launcher binary)
- `.git/`, `.github/`, `.gitignore` — repo metadata
