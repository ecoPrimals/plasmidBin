// SPDX-License-Identifier: AGPL-3.0-or-later

//! `plasmidbin install` — build a primal from local source and install to PATH.
//!
//! Resolves source from the local ecoPrimals workspace (via `ECOPRIMALS_ROOT` +
//! `ecosystem_manifest.toml` local_path), builds with `cargo build --release`,
//! strips the binary (ecoBin standard), and installs to `~/.local/bin/` (or
//! `$ECOPRIMALS_BIN_DIR`).
//!
//! This is the "last mile" that closes the gap between `membrane temporal.cascade`
//! (source sync) and a running binary on a gate. The flow:
//!
//! ```text
//! cascade → local source (with fix) → plasmidbin install → ~/.local/bin/songbird
//! ```

use anyhow::{Context, Result, bail};
use clap::Args;
use plasmidbin_types::arch::Arch;
use plasmidbin_types::provenance::BuildSidecar;
use plasmidbin_types::sources::SourcesFile;
use std::path::{Path, PathBuf};

#[derive(Args)]
pub struct InstallArgs {
    /// Primal to install (source ID from sources.toml, e.g. "songbird")
    primal: String,

    /// Target architecture (default: host)
    #[arg(long)]
    target: Option<String>,

    /// Installation directory (default: ~/.local/bin)
    #[arg(long)]
    dest: Option<PathBuf>,

    /// ecoPrimals workspace root (default: $ECOPRIMALS_ROOT)
    #[arg(long)]
    workspace: Option<PathBuf>,

    /// plasmidBin root directory (for sources.toml)
    #[arg(long, default_value = ".")]
    root: PathBuf,

    /// Skip strip (keep debug symbols)
    #[arg(long)]
    no_strip: bool,

    /// Dry run: show what would be done
    #[arg(long)]
    dry_run: bool,
}

pub fn run(args: InstallArgs) -> Result<()> {
    let arch = match &args.target {
        Some(t) => t.parse::<Arch>()?,
        None => Arch::detect()?,
    };

    let workspace = resolve_workspace(&args.workspace)?;
    let dest = resolve_dest(&args.dest)?;
    let sources = SourcesFile::load(&args.root)?;

    let entry = sources.sources.get(&args.primal).ok_or_else(|| {
        anyhow::anyhow!(
            "primal '{}' not found in sources.toml. Available: {}",
            args.primal,
            sources
                .sources
                .keys()
                .cloned()
                .collect::<Vec<_>>()
                .join(", ")
        )
    })?;

    let bin_name = entry.binary_name(&args.primal);
    let local_path = resolve_local_source(&workspace, &entry.repo)?;

    println!("plasmidbin install");
    println!("  Primal:    {} (binary: {bin_name})", args.primal);
    println!("  Source:    {}", local_path.display());
    println!("  Target:    {}", arch.triple());
    println!("  Dest:      {}", dest.display());
    println!("  Strip:     {}", if args.no_strip { "no" } else { "yes" });

    let source_commit = resolve_git_head(&local_path);
    println!(
        "  Commit:    {}",
        &source_commit[..source_commit.len().min(12)]
    );
    println!();

    if args.dry_run {
        println!(
            "DRY RUN — would build and install {bin_name} to {}",
            dest.join(&bin_name).display()
        );
        return Ok(());
    }

    // Build
    println!("=== Building {bin_name} from local source ===");
    let mut cargo = std::process::Command::new("cargo");
    cargo.args(["build", "--release"]);

    let cross = is_cross_compiling(&arch);
    if cross {
        cargo.args(["--target", arch.triple()]);
    }

    if let Some(ref extra) = entry.build_args {
        cargo.args(extra.split_whitespace());
    }
    cargo.current_dir(&local_path);

    if let Some(linker) = arch.linker() {
        let env_key = format!(
            "CARGO_TARGET_{}_LINKER",
            arch.triple().to_uppercase().replace('-', "_")
        );
        cargo.env(env_key, linker);
    }

    let status = cargo.status().context("cargo build")?;
    if !status.success() {
        bail!("cargo build failed for {}", args.primal);
    }

    // Locate built binary
    let release_dir = if cross {
        local_path
            .join("target")
            .join(arch.triple())
            .join("release")
    } else {
        local_path.join("target").join("release")
    };
    let built_bin = release_dir.join(&bin_name);
    if !built_bin.exists() {
        bail!(
            "binary not found at {} — check build_args or binary_name in sources.toml",
            built_bin.display()
        );
    }

    let built_size = std::fs::metadata(&built_bin)?.len();
    println!(
        "  Built: {} ({:.1} MB)",
        built_bin.display(),
        built_size as f64 / 1_048_576.0
    );

    // Strip
    if !args.no_strip {
        println!("  Stripping...");
        let strip_status = std::process::Command::new("strip").arg(&built_bin).status();
        match strip_status {
            Ok(s) if s.success() => {
                let stripped_size = std::fs::metadata(&built_bin)?.len();
                println!(
                    "  Stripped: {:.1} MB → {:.1} MB",
                    built_size as f64 / 1_048_576.0,
                    stripped_size as f64 / 1_048_576.0
                );
            }
            _ => println!("  WARN: strip failed, installing unstripped"),
        }
    }

    // BLAKE3 checksum
    let binary_bytes = std::fs::read(&built_bin)?;
    let checksum = blake3::hash(&binary_bytes);
    println!("  BLAKE3: {checksum}");

    // Install
    std::fs::create_dir_all(&dest)?;
    let installed_path = dest.join(&bin_name);

    let had_previous = installed_path.exists();
    if had_previous {
        let backup = dest.join(format!("{bin_name}.prev"));
        std::fs::rename(&installed_path, &backup).context("backing up previous binary")?;
        println!("  Backed up previous → {bin_name}.prev");
    }

    std::fs::copy(&built_bin, &installed_path).context("installing binary")?;

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&installed_path, std::fs::Permissions::from_mode(0o755))?;
    }

    // Provenance sidecar
    let provenance_dir = dirs_provenance()?;
    std::fs::create_dir_all(&provenance_dir)?;
    let sidecar = BuildSidecar {
        source_commit,
        source_repo: entry.repo.clone(),
        rustc_version: resolve_rustc_version(),
        build_timestamp: super::defaults::utc_now_rfc3339(),
    };
    let sidecar_path = provenance_dir.join(format!("{bin_name}.provenance.json"));
    match serde_json::to_string_pretty(&sidecar) {
        Ok(json) => {
            std::fs::write(&sidecar_path, json)?;
            println!("  Provenance: {}", sidecar_path.display());
        }
        Err(e) => println!("  WARN: provenance sidecar failed: {e}"),
    }

    println!();
    println!("OK  installed {bin_name} → {}", installed_path.display());
    println!("    checksum: {checksum}");
    if had_previous {
        println!("    previous: {bin_name}.prev (kept as rollback)");
    }

    Ok(())
}

fn resolve_workspace(explicit: &Option<PathBuf>) -> Result<PathBuf> {
    if let Some(p) = explicit {
        return Ok(p.clone());
    }
    if let Ok(root) = std::env::var("ECOPRIMALS_ROOT") {
        return Ok(PathBuf::from(root));
    }
    // Walk up from cwd looking for the workspace marker
    let mut dir = std::env::current_dir()?;
    loop {
        if dir.join("infra").join("wateringHole").exists() {
            return Ok(dir);
        }
        if !dir.pop() {
            break;
        }
    }
    bail!(
        "Cannot resolve ecoPrimals workspace. Set ECOPRIMALS_ROOT or run from within the workspace."
    )
}

fn resolve_dest(explicit: &Option<PathBuf>) -> Result<PathBuf> {
    if let Some(p) = explicit {
        return Ok(p.clone());
    }
    if let Ok(d) = std::env::var("ECOPRIMALS_BIN_DIR") {
        return Ok(PathBuf::from(d));
    }
    if let Ok(d) = std::env::var("XDG_BIN_HOME") {
        return Ok(PathBuf::from(d));
    }
    let home = std::env::var("HOME").context("HOME not set")?;
    Ok(PathBuf::from(home).join(".local").join("bin"))
}

fn dirs_provenance() -> Result<PathBuf> {
    let data_home = std::env::var("XDG_DATA_HOME").unwrap_or_else(|_| {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
        format!("{home}/.local/share")
    });
    Ok(PathBuf::from(data_home)
        .join("ecoPrimals")
        .join("provenance"))
}

/// Map a GitHub org/repo to local workspace path using ecosystem_manifest.toml.
fn resolve_local_source(workspace: &Path, repo: &str) -> Result<PathBuf> {
    let manifest_path = workspace.join("infra/wateringHole/ecosystem_manifest.toml");
    let manifest_content =
        std::fs::read_to_string(&manifest_path).context("reading ecosystem_manifest.toml")?;
    let manifest: toml::Value =
        toml::from_str(&manifest_content).context("parsing ecosystem_manifest.toml")?;

    let repo_name = repo.split('/').next_back().unwrap_or(repo);

    if let Some(repos) = manifest.get("repos").and_then(|r| r.as_table()) {
        if let Some(entry) = repos.get(repo_name) {
            if let Some(local) = entry.get("local_path").and_then(|l| l.as_str()) {
                let full_path = workspace.join(local);
                if full_path.exists() {
                    return Ok(full_path);
                }
            }
        }
    }

    // Fallback: try common layouts
    for prefix in &["primals", "springs", "gardens", "infra"] {
        let guess = workspace.join(prefix).join(repo_name);
        if guess.exists() {
            return Ok(guess);
        }
    }

    bail!(
        "Cannot find local source for '{repo}' in workspace {}. \
         Check ecosystem_manifest.toml local_path.",
        workspace.display()
    )
}

fn is_cross_compiling(arch: &Arch) -> bool {
    Arch::detect()
        .map(|host| host.triple() != arch.triple())
        .unwrap_or(true)
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
