// SPDX-License-Identifier: AGPL-3.0-or-later

//! `plasmidbin bootstrap` — bootstrap a fresh remote gate.

use anyhow::{Context, Result, bail};
use clap::Args;
use std::path::PathBuf;

#[derive(Args)]
pub struct BootstrapArgs {
    /// Remote host (user@host)
    host: String,

    /// Remote plasmidBin directory (env: ECOPRIMALS_PLASMID_BIN)
    #[arg(long, default_value = super::DEFAULT_REMOTE_DIR, env = "ECOPRIMALS_PLASMID_BIN")]
    remote_dir: String,

    /// Composition to launch after bootstrap
    #[arg(long, default_value = "tower")]
    composition: String,

    /// plasmidBin root directory
    #[arg(long, default_value = ".")]
    root: PathBuf,
}

pub fn run(args: BootstrapArgs) -> Result<()> {
    println!("plasmidBin bootstrap");
    println!("Host:        {}", args.host);
    println!("Remote:      {}", args.remote_dir);
    println!("Composition: {}", args.composition);
    println!();

    // Step 1: Clone plasmidBin on remote
    println!("=== Step 1: Clone plasmidBin ===");
    let clone_cmd = format!(
        "test -d {dir}/.git && (cd {dir} && git pull) || git clone https://github.com/ecoPrimals/plasmidBin.git {dir}",
        dir = args.remote_dir
    );
    ssh_run(&args.host, &clone_cmd)?;

    // Step 2: Fetch binaries
    println!("=== Step 2: Fetch binaries ===");
    let fetch_cmd = format!("cd {} && ./fetch.sh --all", args.remote_dir);
    ssh_run(&args.host, &fetch_cmd)?;

    // Step 3: Launch composition
    println!("=== Step 3: Launch {} ===", args.composition);
    let launch_cmd = format!(
        "cd {} && source ports.env && ./nucleus_launcher.sh {}",
        args.remote_dir, args.composition
    );
    ssh_run(&args.host, &launch_cmd)?;

    println!();
    println!("Bootstrap complete on {}", args.host);
    Ok(())
}

fn ssh_run(host: &str, cmd: &str) -> Result<()> {
    println!("  $ ssh {host} '{cmd}'");
    let status = std::process::Command::new("ssh")
        .args([host, cmd])
        .status()
        .context("SSH command")?;
    if !status.success() {
        bail!("SSH command failed");
    }
    Ok(())
}
