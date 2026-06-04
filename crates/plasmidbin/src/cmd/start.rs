// SPDX-License-Identifier: AGPL-3.0-or-later

//! `plasmidbin start` — start a single primal with unified flag mapping.

use anyhow::{Context, Result, bail};
use clap::Args;
use plasmidbin_types::arch::Arch;
use std::path::PathBuf;

#[derive(Args)]
pub struct StartArgs {
    /// Primal name to start
    primal: String,

    /// TCP port
    #[arg(long)]
    tcp_port: Option<u16>,

    /// TCP bind address
    #[arg(long, default_value = "0.0.0.0")]
    tcp_bind: String,

    /// Unix domain socket path
    #[arg(long)]
    socket: Option<PathBuf>,

    /// Family identifier
    #[arg(long)]
    family_id: Option<String>,

    /// BearDog socket for IPC
    #[arg(long)]
    beardog_socket: Option<PathBuf>,

    /// Enable Dark Forest beacon mode
    #[arg(long)]
    dark_forest: bool,

    /// Run in foreground (default: background with nohup)
    #[arg(long)]
    foreground: bool,

    /// Log file path
    #[arg(long)]
    log_file: Option<PathBuf>,

    /// plasmidBin root directory
    #[arg(long, default_value = ".")]
    root: PathBuf,
}

pub fn run(args: StartArgs) -> Result<()> {
    let name = &args.primal;
    let root = &args.root;

    let arch = Arch::detect()?;
    let bin_path = resolve_binary(root, name, arch)
        .ok_or_else(|| anyhow::anyhow!("binary not found for {name}"))?;

    // Check if already running
    if is_running(name) {
        println!("{name} is already running");
        return Ok(());
    }

    let cmd_args = build_primal_args(name, &args);

    println!("Starting {name}...");
    println!("  Binary: {}", bin_path.display());
    println!("  Args:   {}", cmd_args.join(" "));

    if args.foreground {
        let mut cmd = std::process::Command::new(&bin_path);
        cmd.args(&cmd_args);
        apply_primal_env(&mut cmd, name, &args);
        let status = cmd.status().context("starting primal")?;
        if !status.success() {
            bail!("{name} exited with {status}");
        }
    } else {
        let log_file = args
            .log_file
            .as_ref()
            .cloned()
            .unwrap_or_else(|| PathBuf::from(format!("/tmp/{name}.log")));
        let log = std::fs::File::create(&log_file).context("creating log file")?;
        let mut cmd = std::process::Command::new(&bin_path);
        cmd.args(&cmd_args);
        apply_primal_env(&mut cmd, name, &args);
        let child = cmd
            .stdout(log.try_clone()?)
            .stderr(log)
            .spawn()
            .context("spawning primal")?;
        println!("  PID:    {}", child.id());
        println!("  Log:    {}", log_file.display());
    }

    Ok(())
}

fn resolve_binary(root: &std::path::Path, name: &str, arch: Arch) -> Option<PathBuf> {
    let triple_path = root.join("primals").join(arch.triple()).join(name);
    if triple_path.exists() {
        return Some(triple_path);
    }
    let flat_path = root.join("primals").join(name);
    if flat_path.exists() {
        return Some(flat_path);
    }
    None
}

fn is_running(name: &str) -> bool {
    std::process::Command::new("pgrep")
        .args(["-x", name])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

fn build_primal_args(name: &str, args: &StartArgs) -> Vec<String> {
    let mut cmd_args = Vec::new();

    // Most primals use "server" subcommand post-convergence
    match name {
        "beardog" | "songbird" | "toadstool" | "barracuda" | "coralreef" | "nestgate"
        | "rhizocrypt" | "loamspine" | "sweetgrass" | "squirrel" | "petaltongue" | "skunkbat" => {
            cmd_args.push("server".to_string());
        }
        "biomeos" => {
            cmd_args.push("orchestrate".to_string());
        }
        _ => {}
    }

    if let Some(port) = args.tcp_port {
        match name {
            "beardog" => cmd_args.extend(["--port".into(), port.to_string()]),
            "songbird" => cmd_args.extend(["--port".into(), port.to_string()]),
            "biomeos" => cmd_args.extend(["--port".into(), port.to_string()]),
            _ => cmd_args.extend(["--tcp-port".into(), port.to_string()]),
        }
    }

    if let Some(ref socket) = args.socket {
        if name != "barracuda" {
            cmd_args.extend(["--socket".into(), socket.display().to_string()]);
        }
    }

    if let Some(ref fid) = args.family_id {
        if name != "barracuda" {
            cmd_args.extend(["--family-id".into(), fid.clone()]);
        }
    }

    if let Some(ref bs) = args.beardog_socket {
        match name {
            "songbird" => cmd_args.extend(["--security-socket".into(), bs.display().to_string()]),
            _ => cmd_args.extend(["--beardog-socket".into(), bs.display().to_string()]),
        }
    }

    if args.dark_forest {
        cmd_args.push("--dark-forest".into());
    }

    cmd_args
}

fn apply_primal_env(cmd: &mut std::process::Command, name: &str, args: &StartArgs) {
    if name != "barracuda" {
        return;
    }
    if let Some(ref socket) = args.socket {
        cmd.env("BARRACUDA_SOCKET", socket.display().to_string());
    }
    if let Some(ref fid) = args.family_id {
        cmd.env("BARRACUDA_FAMILY_ID", fid);
    }
}
