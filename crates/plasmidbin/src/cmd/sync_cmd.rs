// SPDX-License-Identifier: AGPL-3.0-or-later

//! `plasmidbin sync` — verify local binaries and deploy to genomeBin.
//!
//! Bridges the gap between the harvest/fetch location (repo checkout) and
//! the runtime consumer path (genomeBin) where `nucleus_launcher` discovers
//! primal binaries.
//!
//! Pipeline:
//! 1. Optional `git pull` to refresh the repo checkout
//! 2. BLAKE3 checksum verification against `checksums.toml`
//! 3. Copy verified binaries to genomeBin with canonical layout
//! 4. Create flat symlinks for backward compatibility

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

    /// Sync a single primal by name
    #[arg(long)]
    primal: Option<String>,

    /// Skip deployment to genomeBin (verify only)
    #[arg(long)]
    no_deploy: bool,

    /// Deploy without checksum verification (trust local binaries)
    #[arg(long)]
    force: bool,

    /// Show what would be synced without copying
    #[arg(long)]
    dry_run: bool,

    /// plasmidBin root directory (harvest source)
    #[arg(long, default_value = ".")]
    root: PathBuf,
}

fn genome_bin_dir() -> PathBuf {
    if let Ok(dir) = std::env::var("ECOPRIMALS_PLASMID_BIN") {
        return PathBuf::from(dir);
    }
    let data_home = std::env::var("XDG_DATA_HOME")
        .map(PathBuf::from)
        .or_else(|_| std::env::var("HOME").map(|h| PathBuf::from(h).join(".local/share")))
        .unwrap_or_else(|_| std::env::temp_dir());
    data_home.join("ecoPrimals/plasmidBin")
}

pub fn run(args: SyncArgs) -> Result<()> {
    let root = &args.root;
    let arch = Arch::detect()?;
    let triple = arch.triple();

    println!("plasmidBin sync\n");

    // --- Phase 1: git pull ---
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

    // --- Phase 2: checksum verification ---
    println!("=== Checksum verification ===");
    let checksums = ChecksumsFile::load(root)?;
    let primals_dir = root.join("primals").join(triple);

    let mut current = 0u32;
    let mut stale = 0u32;
    let mut missing = 0u32;
    let mut verified_primals: Vec<(String, PathBuf)> = Vec::new();

    for (name, hashes) in &checksums.primals {
        if let Some(ref filter) = args.primal {
            if name != filter {
                continue;
            }
        }

        let Some(expected) = hashes.get(triple) else {
            continue;
        };

        let bin_path = primals_dir.join(name);
        let flat_path = root.join("primals").join(name);

        let resolved = if bin_path.exists() {
            bin_path
        } else if flat_path.exists() {
            flat_path
        } else {
            println!("  [{name}] MISSING");
            missing += 1;
            continue;
        };

        if args.force {
            println!("  [{name}] FORCE (skipping verification)");
            current += 1;
            verified_primals.push((name.clone(), resolved));
            continue;
        }

        let data = std::fs::read(&resolved)?;
        let actual = blake3::hash(&data).to_hex().to_string();

        if actual == *expected {
            println!("  [{name}] CURRENT");
            current += 1;
            verified_primals.push((name.clone(), resolved));
        } else {
            println!("  [{name}] STALE (local differs from checksums.toml)");
            stale += 1;
        }
    }

    println!();
    println!("Verification:");
    println!("  Current: {current}");
    println!("  Stale:   {stale}");
    println!("  Missing: {missing}");

    if stale > 0 {
        println!("\nRun: plasmidbin fetch --force --all   to update stale binaries");
    }

    // --- Phase 3: deploy to genomeBin ---
    if args.no_deploy {
        return Ok(());
    }

    let dest = genome_bin_dir();
    let dest_primals = dest.join("primals").join(triple);

    println!();
    println!("=== Deploy to genomeBin ===");
    println!("Destination: {}", dest.display());

    if args.dry_run {
        for (name, src) in &verified_primals {
            let target = dest_primals.join(name);
            if target.exists() {
                let src_meta = std::fs::metadata(src)?;
                let dst_meta = std::fs::metadata(&target)?;
                if src_meta.len() == dst_meta.len() {
                    println!("  [{name}] UP-TO-DATE (skip)");
                    continue;
                }
            }
            println!("  [{name}] WOULD COPY  {} -> {}", src.display(), target.display());
        }
        println!("\n(dry-run — no files modified)");
        return Ok(());
    }

    std::fs::create_dir_all(&dest_primals)?;

    let mut deployed = 0u32;
    let mut up_to_date = 0u32;

    for (name, src) in &verified_primals {
        let target = dest_primals.join(name);

        if target.exists() {
            let src_data = std::fs::read(src)?;
            let dst_data = std::fs::read(&target)?;
            if blake3::hash(&src_data) == blake3::hash(&dst_data) {
                println!("  [{name}] UP-TO-DATE");
                up_to_date += 1;
                continue;
            }
        }

        std::fs::copy(src, &target)
            .with_context(|| format!("copying {name} to {}", target.display()))?;

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&target, std::fs::Permissions::from_mode(0o755));
        }

        println!("  [{name}] DEPLOYED");
        deployed += 1;
    }

    // Flat symlinks for backward compat
    let flat_dir = dest.join("primals");
    let mut symlinked = 0u32;
    for (name, _) in &verified_primals {
        let link = flat_dir.join(name);
        if link.exists() && !link.is_symlink() {
            continue;
        }
        #[cfg(unix)]
        {
            let _ = std::fs::remove_file(&link);
            let rel_target = format!("{triple}/{name}");
            std::os::unix::fs::symlink(&rel_target, &link)?;
            symlinked += 1;
        }
    }

    // Copy metadata files if not present at destination
    for meta_file in &["manifest.toml", "checksums.toml", "sources.toml", "ports.env"] {
        let src = root.join(meta_file);
        let dst = dest.join(meta_file);
        if src.exists() && !dst.exists() {
            std::fs::copy(&src, &dst)?;
            println!("  [metadata] copied {meta_file}");
        }
    }

    println!();
    println!("Deploy:");
    println!("  Deployed:    {deployed}");
    println!("  Up-to-date:  {up_to_date}");
    println!("  Symlinked:   {symlinked}");
    println!();

    if deployed > 0 {
        println!("genomeBin updated. nucleus_launcher will discover these binaries.");
    }

    Ok(())
}
