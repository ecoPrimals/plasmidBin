// SPDX-License-Identifier: AGPL-3.0-or-later

//! `plasmidbin sync` — pull latest metadata and re-verify local binaries.

use anyhow::{Context, Result, bail};
use clap::Args;
use plasmidbin_types::arch::Arch;
use plasmidbin_types::checksums::ChecksumsFile;
use std::path::PathBuf;

#[derive(Args)]
pub struct SyncArgs {
    /// Skip git pull
    #[arg(long)]
    no_pull: bool,

    /// plasmidBin root directory
    #[arg(long, default_value = ".")]
    root: PathBuf,
}

pub fn run(args: SyncArgs) -> Result<()> {
    let root = &args.root;
    let arch = Arch::detect()?;

    println!("plasmidBin sync\n");

    if !args.no_pull {
        println!("=== git pull ===");
        let status = std::process::Command::new("git")
            .arg("pull")
            .current_dir(root)
            .status()
            .context("running git pull")?;
        if !status.success() {
            bail!("git pull failed");
        }
        println!();
    }

    println!("=== Checksum verification ===");
    let checksums = ChecksumsFile::load(root)?;
    let primals_dir = root.join("primals").join(arch.triple());

    let mut current = 0u32;
    let mut stale = 0u32;
    let mut missing = 0u32;

    for (name, hashes) in &checksums.primals {
        let Some(expected) = hashes.get(arch.triple()) else {
            continue;
        };

        let bin_path = primals_dir.join(name);
        if !bin_path.exists() {
            let flat = root.join("primals").join(name);
            if !flat.exists() {
                println!("  [{name}] MISSING");
                missing += 1;
                continue;
            }
        }

        let path = if bin_path.exists() {
            &bin_path
        } else {
            &root.join("primals").join(name)
        };
        let data = std::fs::read(path)?;
        let actual = blake3::hash(&data).to_hex().to_string();

        if actual == *expected {
            println!("  [{name}] CURRENT");
            current += 1;
        } else {
            println!("  [{name}] STALE (local differs from checksums.toml)");
            stale += 1;
        }
    }

    println!();
    println!("Summary:");
    println!("  Current: {current}");
    println!("  Stale:   {stale}");
    println!("  Missing: {missing}");

    if stale > 0 {
        println!("\nRun: plasmidbin fetch --force --all   to update stale binaries");
    }

    Ok(())
}
