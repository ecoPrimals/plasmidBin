// SPDX-License-Identifier: AGPL-3.0-or-later

mod validate;
mod harvest;
mod fetch;
mod doctor;
mod sync_cmd;
mod start;
mod launch;
mod cell;
mod stage_usb;
mod stop;
mod deploy;
mod bootstrap;
mod build;
mod update;
mod seed;
mod verify_provenance;

use clap::Subcommand;

/// Default remote directory for primal binaries on gates/VPS.
/// Override with `ECOPRIMALS_PLASMID_BIN`.
pub(crate) const DEFAULT_REMOTE_DIR: &str = "/opt/plasmidBin";

/// Resolved remote plasmidBin directory (env override or compile-time default).
pub(crate) fn remote_dir_default() -> String {
    std::env::var("ECOPRIMALS_PLASMID_BIN")
        .unwrap_or_else(|_| DEFAULT_REMOTE_DIR.to_string())
}

/// Returns the real UID of the calling process.
pub(crate) fn current_uid() -> u32 {
    // SAFETY: getuid() is always safe — it's a pure read of process metadata.
    unsafe { libc::getuid() }
}

#[derive(Subcommand)]
pub enum Command {
    /// Validate metadata integrity: manifest, checksums, ports, sources
    Validate(validate::ValidateArgs),
    /// Harvest built binaries: validate, strip, checksum, stage
    Harvest(harvest::HarvestArgs),
    /// Download binaries from GitHub Releases with BLAKE3 verification
    Fetch(fetch::FetchArgs),
    /// Health check: prerequisites, binary inventory, checksums, sockets
    Doctor(doctor::DoctorArgs),
    /// Pull latest metadata and re-verify local binaries
    Sync(sync_cmd::SyncArgs),
    /// Start a single primal with unified flag mapping
    Start(start::StartArgs),
    /// Launch a full NUCLEUS composition in dependency order
    Launch(launch::LaunchArgs),
    /// Deploy cell graphs from cells/*.toml
    Cell(cell::CellArgs),
    /// Stage binaries for USB / offline deployment
    StageUsb(stage_usb::StageUsbArgs),
    /// Stop primal processes (local or remote)
    Stop(stop::StopArgs),
    /// Deploy to remote gate, Pixel, or membrane VPS
    Deploy(deploy::DeployArgs),
    /// Bootstrap a fresh remote gate
    Bootstrap(bootstrap::BootstrapArgs),
    /// Build a primal from source for a target triple
    Build(build::BuildArgs),
    /// Check upstream releases and update local binaries
    Update(update::UpdateArgs),
    /// Dark Forest seed lifecycle via BearDog crypto
    Seed(seed::SeedArgs),
    /// Verify provenance chain: composite hashes, checksum cross-ref, braids
    VerifyProvenance(verify_provenance::VerifyProvenanceArgs),
}

impl Command {
    pub fn run(self) -> anyhow::Result<()> {
        match self {
            Command::Validate(args) => validate::run(args),
            Command::Harvest(args) => harvest::run(args),
            Command::Fetch(args) => fetch::run(args),
            Command::Doctor(args) => doctor::run(args),
            Command::Sync(args) => sync_cmd::run(args),
            Command::Start(args) => start::run(args),
            Command::Launch(args) => launch::run(args),
            Command::Cell(args) => cell::run(args),
            Command::StageUsb(args) => stage_usb::run(args),
            Command::Stop(args) => stop::run(args),
            Command::Deploy(args) => deploy::run(args),
            Command::Bootstrap(args) => bootstrap::run(args),
            Command::Build(args) => build::run(args),
            Command::Update(args) => update::run(args),
            Command::Seed(args) => seed::run(args),
            Command::VerifyProvenance(args) => verify_provenance::run(args),
        }
    }
}
