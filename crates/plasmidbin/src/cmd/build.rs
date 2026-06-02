// SPDX-License-Identifier: AGPL-3.0-or-later

//! `plasmidbin build` — build a primal from source for a target triple.

use anyhow::{Context, Result, bail};
use clap::Args;
use plasmidbin_types::arch::Arch;
use plasmidbin_types::provenance::BuildSidecar;
use plasmidbin_types::sources::SourcesFile;
use std::path::{Path, PathBuf};

#[derive(Args)]
pub struct BuildArgs {
    /// Primal to build (source ID from sources.toml, or "all")
    primal: String,

    /// Target architecture
    #[arg(long)]
    target: Option<String>,

    /// Pin build to a specific git commit SHA (otherwise builds main HEAD)
    #[arg(long)]
    commit: Option<String>,

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
    let build_dir = super::defaults::build_dir();
    let deploy_dir = super::defaults::deploy_dir(arch.triple());

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

        if let Some(ref sha) = args.commit {
            println!("  Pinning to commit {}", &sha[..sha.len().min(12)]);
            let fetch_ok = std::process::Command::new("git")
                .args(["fetch", "origin", sha])
                .current_dir(&clone_dir)
                .status()
                .map(|s| s.success())
                .unwrap_or(false);
            if fetch_ok {
                let co = std::process::Command::new("git")
                    .args(["checkout", sha])
                    .current_dir(&clone_dir)
                    .status()
                    .context("git checkout commit")?;
                if !co.success() {
                    println!("  WARN: checkout {sha} failed, building HEAD");
                }
            } else {
                println!("  WARN: fetch {sha} failed (shallow clone?), building HEAD");
            }

            // Remove the cached release binary so cargo is forced to re-link.
            // Without this, a persistent runner target dir can serve a stale
            // binary even though crate compilation was re-run.
            let bin_name = entry.binary_name(id);
            let cached_bin = clone_dir
                .join("target")
                .join(arch.triple())
                .join("release")
                .join(&bin_name);
            if cached_bin.exists() {
                let _ = std::fs::remove_file(&cached_bin);
                println!("  Cleared cached binary to force re-link");
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
            let staged_path = deploy_dir.join(&bin_name);
            std::fs::copy(&built_bin, &staged_path)?;
            println!("  OK: staged {bin_name}");

            // Write provenance sidecar next to the staged binary
            let source_commit = resolve_git_head(&clone_dir);
            let rustc_version = resolve_rustc_version();
            let sidecar = BuildSidecar {
                source_commit,
                source_repo: entry.repo.clone(),
                rustc_version,
                build_timestamp: super::defaults::utc_now_rfc3339(),
            };
            match BuildSidecar::write_next_to(&staged_path, &sidecar) {
                Ok(()) => println!("  OK: wrote provenance sidecar"),
                Err(e) => println!("  WARN: provenance sidecar failed: {e}"),
            }

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

fn resolve_git_head(repo_dir: &Path) -> String {
    std::process::Command::new("git")
        .args(["rev-parse", "HEAD"])
        .current_dir(repo_dir)
        .output()
        .ok()
        .and_then(|o| {
            if o.status.success() {
                Some(String::from_utf8_lossy(&o.stdout).trim().to_string())
            } else {
                None
            }
        })
        .unwrap_or_else(|| "unknown".into())
}

fn resolve_rustc_version() -> String {
    std::process::Command::new("rustc")
        .arg("--version")
        .output()
        .ok()
        .and_then(|o| {
            if o.status.success() {
                let full = String::from_utf8_lossy(&o.stdout).trim().to_string();
                full.split_whitespace().nth(1).map(String::from)
            } else {
                None
            }
        })
        .unwrap_or_else(|| "unknown".into())
}
