// SPDX-License-Identifier: AGPL-3.0-or-later

//! `plasmidbin deploy` — deploy to remote gate, Pixel, or membrane VPS.

use anyhow::{Context, Result, bail};
use clap::{Args, Subcommand};
use plasmidbin_types::arch::Arch;
use plasmidbin_types::KNOWN_PRIMALS;
use std::path::PathBuf;

#[derive(Args)]
pub struct DeployArgs {
    #[command(subcommand)]
    target: DeployTarget,
}

#[derive(Subcommand)]
enum DeployTarget {
    /// Deploy to a remote gate via SSH
    Gate(GateArgs),
    /// Deploy to Android/Pixel via ADB
    Pixel(PixelArgs),
    /// Deploy membrane VPS (Songbird relay, Tower, Nest)
    Membrane(MembraneArgs),
}

#[derive(Args)]
struct GateArgs {
    /// Remote host (user@host)
    host: String,

    /// Remote plasmidBin directory (env: ECOPRIMALS_PLASMID_BIN)
    #[arg(long, default_value = super::defaults::DEFAULT_REMOTE_DIR, env = "ECOPRIMALS_PLASMID_BIN")]
    remote_dir: String,

    /// Target architecture for the remote gate
    #[arg(long)]
    arch: Option<String>,

    /// Only deploy specific primals
    #[arg(long)]
    primal: Option<String>,

    /// plasmidBin root directory
    #[arg(long, default_value = ".")]
    root: PathBuf,
}

#[derive(Args)]
struct PixelArgs {
    /// ADB serial number (if multiple devices)
    #[arg(long)]
    serial: Option<String>,

    /// plasmidBin root directory
    #[arg(long, default_value = ".")]
    root: PathBuf,
}

#[derive(Args)]
struct MembraneArgs {
    /// Remote host (user@host)
    host: String,

    /// plasmidBin root directory
    #[arg(long, default_value = ".")]
    root: PathBuf,
}

pub fn run(args: DeployArgs) -> Result<()> {
    match args.target {
        DeployTarget::Gate(a) => deploy_gate(a),
        DeployTarget::Pixel(a) => deploy_pixel(a),
        DeployTarget::Membrane(a) => deploy_membrane(a),
    }
}

fn deploy_gate(args: GateArgs) -> Result<()> {
    let root = &args.root;
    let arch: Arch = match &args.arch {
        Some(a) => a.parse().map_err(|e: String| anyhow::anyhow!(e))?,
        None => Arch::detect().map_err(|e| anyhow::anyhow!(e))?,
    };

    println!("plasmidBin deploy gate");
    println!("Host:   {}", args.host);
    println!("Arch:   {}", arch.triple());
    println!("Remote: {}", args.remote_dir);
    println!();

    // Create remote directory structure
    ssh_run(&args.host, &format!("mkdir -p {}/primals/{}", args.remote_dir, arch.triple()))?;

    let source_dir = root.join("primals").join(arch.triple());
    let mut deployed = 0u32;

    for name in KNOWN_PRIMALS {
        if let Some(ref filter) = args.primal {
            if name != filter { continue; }
        }

        let src = source_dir.join(name);
        if !src.exists() { continue; }

        let remote_path = format!("{}/primals/{}/{name}", args.remote_dir, arch.triple());
        println!("  [{name}] deploying...");

        let status = std::process::Command::new("scp")
            .args(["-q", &src.display().to_string(), &format!("{}:{}", args.host, remote_path)])
            .status()
            .context("scp")?;

        if status.success() {
            ssh_run(&args.host, &format!("chmod +x {remote_path}"))?;
            println!("  [{name}] OK");
            deployed += 1;
        } else {
            println!("  [{name}] FAIL");
        }
    }

    // Copy metadata
    for meta in &["ports.env", "checksums.toml"] {
        let src = root.join(meta);
        if src.exists() {
            let _ = std::process::Command::new("scp")
                .args(["-q", &src.display().to_string(), &format!("{}:{}/{}", args.host, args.remote_dir, meta)])
                .status();
        }
    }

    println!("\nDeployed {deployed} binaries to {}", args.host);
    Ok(())
}

fn deploy_pixel(args: PixelArgs) -> Result<()> {
    let root = &args.root;
    let arch = Arch::Aarch64;
    let source_dir = root.join("primals").join(arch.triple());
    let remote_dir = "/data/local/tmp/plasmidBin/primals";

    println!("plasmidBin deploy pixel");
    println!("Arch: aarch64");
    println!();

    let mut adb = vec!["adb".to_string()];
    if let Some(ref serial) = args.serial {
        adb.extend(["-s".into(), serial.clone()]);
    }

    // Create remote directory
    let mut mkdir_cmd = adb.clone();
    mkdir_cmd.extend(["shell".into(), format!("mkdir -p {remote_dir}")]);
    std::process::Command::new(&mkdir_cmd[0])
        .args(&mkdir_cmd[1..])
        .status()
        .context("adb mkdir")?;

    let mut deployed = 0u32;
    for name in KNOWN_PRIMALS {
        let src = source_dir.join(name);
        if !src.exists() { continue; }

        let mut push_cmd = adb.clone();
        push_cmd.extend(["push".into(), src.display().to_string(), format!("{remote_dir}/{name}")]);

        let status = std::process::Command::new(&push_cmd[0])
            .args(&push_cmd[1..])
            .status()
            .context("adb push")?;

        if status.success() {
            let mut chmod_cmd = adb.clone();
            chmod_cmd.extend(["shell".into(), format!("chmod +x {remote_dir}/{name}")]);
            let _ = std::process::Command::new(&chmod_cmd[0])
                .args(&chmod_cmd[1..])
                .status();
            println!("  [{name}] OK");
            deployed += 1;
        }
    }

    println!("\nDeployed {deployed} binaries to Pixel");
    Ok(())
}

fn deploy_membrane(args: MembraneArgs) -> Result<()> {
    let root = &args.root;

    println!("plasmidBin deploy membrane");
    println!("Host: {}", args.host);
    println!();

    // Deploy systemd units
    let membrane_dir = root.join("membrane");
    if !membrane_dir.exists() {
        bail!("membrane/ directory not found");
    }

    let entries: Vec<_> = std::fs::read_dir(&membrane_dir)?
        .flatten()
        .filter(|e| {
            e.path().extension().is_some_and(|ext| ext == "service")
        })
        .collect();

    for entry in &entries {
        let name = entry.file_name();
        println!("  Deploying {}", name.to_string_lossy());
        let _ = std::process::Command::new("scp")
            .args([
                "-q",
                &entry.path().display().to_string(),
                &format!("{}:/etc/systemd/system/{}", args.host, name.to_string_lossy()),
            ])
            .status();
    }

    // Reload systemd
    ssh_run(&args.host, "systemctl daemon-reload")?;

    println!("\nDeployed {} service units", entries.len());
    Ok(())
}

fn ssh_run(host: &str, cmd: &str) -> Result<()> {
    let status = std::process::Command::new("ssh")
        .args([host, cmd])
        .status()
        .context("SSH command")?;
    if !status.success() {
        bail!("SSH command failed: {cmd}");
    }
    Ok(())
}
