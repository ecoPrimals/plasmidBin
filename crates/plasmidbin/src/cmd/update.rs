// SPDX-License-Identifier: AGPL-3.0-or-later

//! `plasmidbin update` — check upstream releases and update local binaries.

use anyhow::{Context, Result};
use clap::Args;
use plasmidbin_types::arch::Arch;
use plasmidbin_types::sources::SourcesFile;
use std::path::PathBuf;

#[derive(Args)]
pub struct UpdateArgs {
    /// Only check, don't download
    #[arg(long)]
    check_only: bool,

    /// Update a specific primal
    #[arg(long)]
    primal: Option<String>,

    /// plasmidBin root directory
    #[arg(long, default_value = ".")]
    root: PathBuf,
}

pub fn run(args: UpdateArgs) -> Result<()> {
    let root = &args.root;
    let arch = Arch::detect().map_err(|e| anyhow::anyhow!(e))?;
    let sources = SourcesFile::load(root).map_err(|e| anyhow::anyhow!(e))?;

    println!("plasmidBin update");
    println!("Arch: {}", arch.triple());
    println!();

    let mut updates = 0u32;
    let mut current = 0u32;

    for (id, entry) in &sources.sources {
        if let Some(ref filter) = args.primal {
            if id != filter { continue; }
        }

        print!("  [{id}] ");

        let latest_tag = get_latest_release(&entry.repo);
        match latest_tag {
            Some(ref tag) => {
                let bin_name = entry.binary_name(id);
                let local = root.join("primals").join(arch.triple()).join(&bin_name);

                if local.exists() {
                    println!("local present, latest release: {tag}");
                    current += 1;
                } else {
                    println!("MISSING locally, latest release: {tag}");
                    if !args.check_only {
                        let asset_name = format!("{bin_name}-{}", arch.triple());
                        let url = format!(
                            "https://github.com/{}/releases/download/{tag}/{asset_name}",
                            entry.repo
                        );
                        let dest = root.join("primals").join(arch.triple()).join(&bin_name);
                        let parent = dest
                            .parent()
                            .ok_or_else(|| anyhow::anyhow!("invalid destination path"))?;
                        std::fs::create_dir_all(parent)?;

                        let status = std::process::Command::new("curl")
                            .args(["-sfL", "--max-time", "120", "-o"])
                            .arg(&dest)
                            .arg(&url)
                            .status()
                            .context("downloading")?;

                        if status.success() {
                            #[cfg(unix)]
                            {
                                use std::os::unix::fs::PermissionsExt;
                                let _ = std::fs::set_permissions(&dest, std::fs::Permissions::from_mode(0o755));
                            }
                            println!("    Downloaded from {tag}");
                            updates += 1;
                        } else {
                            println!("    Download failed");
                        }
                    }
                }
            }
            None => {
                if entry.private {
                    println!("private repo, skipping release check");
                } else {
                    println!("no releases found");
                }
            }
        }
    }

    println!();
    println!("Summary: {current} current, {updates} updated");
    Ok(())
}

fn get_latest_release(repo: &str) -> Option<String> {
    let output = std::process::Command::new("gh")
        .args(["release", "view", "--repo", repo, "--json", "tagName", "-q", ".tagName"])
        .output()
        .ok()?;
    if output.status.success() {
        let tag = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if tag.is_empty() { None } else { Some(tag) }
    } else {
        None
    }
}
