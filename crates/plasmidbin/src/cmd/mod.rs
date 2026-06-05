// SPDX-License-Identifier: AGPL-3.0-or-later

mod bootstrap;
mod build;
mod cell;
pub(crate) mod defaults;
mod deploy;
mod doctor;
mod fetch;
mod harvest;
mod install;
mod launch;
mod rehash;
mod seed;
mod stage_usb;
mod start;
mod stop;
mod sync_cmd;
mod update;
mod validate;
mod verify_provenance;

use clap::Subcommand;

/// Returns the real UID of the calling process (no libc, no unsafe).
///
/// Reads from `/proc/self/status` on Linux. Falls back to 1000 if
/// the proc filesystem is unavailable (containers, non-Linux).
pub(crate) fn current_uid() -> u32 {
    std::fs::read_to_string("/proc/self/status")
        .ok()
        .and_then(|s| {
            s.lines()
                .find(|l| l.starts_with("Uid:"))
                .and_then(|l| l.split_whitespace().nth(1))
                .and_then(|v| v.parse().ok())
        })
        .unwrap_or(1000)
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
    /// Build from local workspace source and install to ~/.local/bin
    Install(install::InstallArgs),
    /// Check upstream releases and update local binaries
    Update(update::UpdateArgs),
    /// Dark Forest seed lifecycle via BearDog crypto
    Seed(seed::SeedArgs),
    /// Verify provenance chain: composite hashes, checksum cross-ref, braids
    VerifyProvenance(verify_provenance::VerifyProvenanceArgs),
    /// Recompute BLAKE3 checksums for local binaries
    Rehash(rehash::RehashArgs),
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
            Command::Install(args) => install::run(args),
            Command::Update(args) => update::run(args),
            Command::Seed(args) => seed::run(args),
            Command::VerifyProvenance(args) => verify_provenance::run(args),
            Command::Rehash(args) => rehash::run(args),
        }
    }
}
