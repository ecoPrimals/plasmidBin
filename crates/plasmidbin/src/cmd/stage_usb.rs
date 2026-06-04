// SPDX-License-Identifier: AGPL-3.0-or-later

//! `plasmidbin stage-usb` — stage binaries for USB / offline deployment.

use anyhow::{Context, Result, bail};
use clap::Args;
use plasmidbin_types::KNOWN_PRIMALS;
use plasmidbin_types::arch::Arch;
use std::path::PathBuf;

#[derive(Args)]
pub struct StageUsbArgs {
    /// Destination directory
    #[arg(long)]
    dest: PathBuf,

    /// Target architecture
    #[arg(long)]
    arch: Option<String>,

    /// Composition to stage (nucleus, full, tower)
    #[arg(long, default_value = "full")]
    composition: String,

    /// Dry run — show what would be staged
    #[arg(long)]
    dry_run: bool,

    /// Verify checksums after copy
    #[arg(long)]
    verify: bool,

    /// plasmidBin root directory
    #[arg(long, default_value = ".")]
    root: PathBuf,
}

pub fn run(args: StageUsbArgs) -> Result<()> {
    let root = &args.root;
    let arch: Arch = match &args.arch {
        Some(a) => a.parse()?,
        None => Arch::detect()?,
    };

    let triple = arch.triple();
    let source_dir = root.join("primals").join(triple);
    let dest_primals = args.dest.join("primals").join(triple);

    println!("plasmidBin stage-usb");
    println!("Source: {}", source_dir.display());
    println!("Dest:   {}", dest_primals.display());
    println!("Arch:   {triple}");
    println!();

    if !source_dir.exists() {
        bail!("source directory not found: {}", source_dir.display());
    }

    if !args.dry_run {
        std::fs::create_dir_all(&dest_primals).context("creating dest")?;
    }

    let mut staged = 0u32;
    let mut skipped = 0u32;

    for name in KNOWN_PRIMALS {
        let src = source_dir.join(name);
        if !src.exists() {
            println!("  [{name}] SKIP  not present");
            skipped += 1;
            continue;
        }

        let dest = dest_primals.join(name);
        let size = human_size(std::fs::metadata(&src)?.len());

        if args.dry_run {
            println!("  [{name}] STAGE  {size} [dry-run]");
            staged += 1;
            continue;
        }

        std::fs::copy(&src, &dest).with_context(|| format!("copying {name}"))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&dest, std::fs::Permissions::from_mode(0o755));
        }

        if args.verify {
            let src_data = std::fs::read(&src)?;
            let dst_data = std::fs::read(&dest)?;
            let src_hash = blake3::hash(&src_data).to_hex().to_string();
            let dst_hash = blake3::hash(&dst_data).to_hex().to_string();
            if src_hash != dst_hash {
                bail!("{name}: post-copy checksum mismatch");
            }
        }

        println!("  [{name}] OK  {size}");
        staged += 1;
    }

    // Copy metadata files
    if !args.dry_run {
        for meta in &["manifest.toml", "checksums.toml", "ports.env"] {
            let src = root.join(meta);
            if src.exists() {
                std::fs::copy(&src, args.dest.join(meta))?;
            }
        }

        // Write VERSION file
        let version = format!(
            "staged: {}\narch: {triple}\ncommit: {}\n",
            chrono_now(),
            git_head(root),
        );
        std::fs::write(args.dest.join("VERSION"), version)?;
    }

    println!();
    println!("Summary: {staged} staged, {skipped} skipped");
    Ok(())
}

use super::defaults::human_size;

fn chrono_now() -> String {
    let output = std::process::Command::new("date").arg("-Iseconds").output();
    match output {
        Ok(o) => String::from_utf8_lossy(&o.stdout).trim().to_string(),
        Err(_) => "unknown".into(),
    }
}

fn git_head(root: &std::path::Path) -> String {
    let output = std::process::Command::new("git")
        .args(["rev-parse", "--short", "HEAD"])
        .current_dir(root)
        .output();
    match output {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).trim().to_string(),
        _ => "unknown".into(),
    }
}
