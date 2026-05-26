// SPDX-License-Identifier: AGPL-3.0-or-later

//! `plasmidbin build` — build a primal from source for a target triple.

use anyhow::{Context, Result, bail};
use clap::Args;
use plasmidbin_types::arch::Arch;
use plasmidbin_types::sources::SourcesFile;
use std::path::PathBuf;

#[derive(Args)]
pub struct BuildArgs {
    /// Primal to build (source ID from sources.toml, or "all")
    primal: String,

    /// Target architecture
    #[arg(long)]
    target: Option<String>,

    /// Also run harvest after build
    #[arg(long)]
    harvest: bool,

    /// plasmidBin root directory
    #[arg(long, default_value = ".")]
    root: PathBuf,
}

pub fn run(args: BuildArgs) -> Result<()> {
    let root = &args.root;
    let arch: Arch = match &args.target {
        Some(t) => t.parse().map_err(|e: String| anyhow::anyhow!(e))?,
        None => Arch::detect().map_err(|e| anyhow::anyhow!(e))?,
    };

    let sources = SourcesFile::load(root).map_err(|e| anyhow::anyhow!(e))?;
    let build_dir = PathBuf::from("/tmp/primalspring-build");
    let deploy_dir = PathBuf::from(format!("/tmp/primalspring-deploy/primals/{}", arch.triple()));

    std::fs::create_dir_all(&build_dir)?;
    std::fs::create_dir_all(&deploy_dir)?;

    let primals_to_build: Vec<(String, &plasmidbin_types::sources::SourceEntry)> = if args.primal == "all" {
        sources.sources.iter().map(|(k, v)| (k.clone(), v)).collect()
    } else {
        let entry = sources.sources.get(&args.primal)
            .ok_or_else(|| anyhow::anyhow!("primal '{}' not found in sources.toml", args.primal))?;
        vec![(args.primal.clone(), entry)]
    };

    println!("plasmidBin build");
    println!("Target: {}", arch.triple());
    println!("Primals: {}", primals_to_build.len());
    println!();

    let mut built = 0u32;
    let mut failed = 0u32;

    for (id, entry) in &primals_to_build {
        println!("=== Building {id} ({}) ===", entry.repo);

        let clone_dir = build_dir.join(id);
        let repo_url = format!("https://github.com/{}.git", entry.repo);

        // Clone or pull
        if clone_dir.join(".git").exists() {
            let status = std::process::Command::new("git")
                .args(["pull"])
                .current_dir(&clone_dir)
                .status()
                .context("git pull")?;
            if !status.success() {
                println!("  WARN: git pull failed, trying fresh clone");
                let _ = std::fs::remove_dir_all(&clone_dir);
            }
        }

        if !clone_dir.exists() {
            let status = std::process::Command::new("git")
                .args(["clone", "--depth", "1", &repo_url, &clone_dir.display().to_string()])
                .status()
                .context("git clone")?;
            if !status.success() {
                println!("  FAIL: git clone failed for {}", entry.repo);
                failed += 1;
                continue;
            }
        }

        // Build
        let mut cargo = std::process::Command::new("cargo");
        cargo.args(["build", "--release", "--target", arch.triple()]);
        if let Some(ref extra) = entry.build_args {
            cargo.args(extra.split_whitespace());
        }
        cargo.current_dir(&clone_dir);

        if let Some(linker) = arch.linker() {
            let env_key = format!("CARGO_TARGET_{}_LINKER", arch.triple().to_uppercase().replace('-', "_"));
            cargo.env(env_key, linker);
        }

        let status = cargo.status().context("cargo build")?;
        if !status.success() {
            println!("  FAIL: cargo build failed");
            failed += 1;
            continue;
        }

        // Stage binary (plain name — triple is encoded in the directory)
        let bin_name = entry.binary_name(id);
        let built_bin = clone_dir.join("target").join(arch.triple()).join("release").join(&bin_name);
        if built_bin.exists() {
            std::fs::copy(&built_bin, deploy_dir.join(&bin_name))?;
            println!("  OK: staged {bin_name}");
            built += 1;
        } else {
            println!("  FAIL: binary not found at {}", built_bin.display());
            failed += 1;
        }
    }

    println!();
    println!("Summary: {built} built, {failed} failed");

    if args.harvest && built > 0 {
        println!("\n=== Running harvest ===");
        let status = std::process::Command::new("cargo")
            .args(["run", "-p", "plasmidbin", "--", "harvest", "--arch", arch.triple(), "--source", &deploy_dir.display().to_string()])
            .current_dir(root)
            .status()
            .context("harvest")?;
        if !status.success() {
            bail!("harvest failed");
        }
    }

    if failed > 0 { bail!("{failed} builds failed"); }
    Ok(())
}
