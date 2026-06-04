// SPDX-License-Identifier: AGPL-3.0-or-later

//! `plasmidbin launch` — start a full NUCLEUS composition in dependency order.

use anyhow::{Context, Result};
use clap::Args;
use plasmidbin_types::arch::Arch;
use plasmidbin_types::ports;
use std::path::PathBuf;

#[derive(Args)]
pub struct LaunchArgs {
    /// Composition name (tower, node, nest, nucleus, full)
    #[arg(default_value = "nucleus")]
    composition: String,

    /// Family identifier
    #[arg(long)]
    family_id: Option<String>,

    /// plasmidBin root directory
    #[arg(long, default_value = ".")]
    root: PathBuf,
}

const LAUNCH_ORDER: &[&str] = &[
    "beardog",
    "skunkbat",
    "songbird",
    "nestgate",
    "rhizocrypt",
    "loamspine",
    "sweetgrass",
    "toadstool",
    "barracuda",
    "coralreef",
    "squirrel",
    "petaltongue",
    "biomeos",
];

pub fn run(args: LaunchArgs) -> Result<()> {
    let root = &args.root;
    let arch = Arch::detect()?;
    let port_map = ports::load_port_map(root)?;
    let compositions = ports::load_compositions(root)?;

    let comp_key = format!("COMP_{}", args.composition.to_uppercase());
    let primals: Vec<String> = compositions
        .get(&comp_key)
        .cloned()
        .unwrap_or_else(|| LAUNCH_ORDER.iter().map(|s| s.to_string()).collect());

    println!("plasmidBin launch — {}", args.composition);
    println!("Composition: {} primals", primals.len());
    println!();

    let mut launched = 0u32;
    let mut skipped = 0u32;

    for name in LAUNCH_ORDER {
        if !primals.contains(&name.to_string()) {
            continue;
        }

        let bin = resolve_binary(root, name, arch);
        let Some(bin_path) = bin else {
            println!("  [{name}] SKIP  binary not found");
            skipped += 1;
            continue;
        };

        if is_running(name) {
            println!("  [{name}] RUNNING  (already up)");
            skipped += 1;
            continue;
        }

        let port = port_map.get(*name).copied();
        let mut cmd_args: Vec<String> = Vec::new();

        // Server subcommand
        if *name == "biomeos" {
            cmd_args.push("orchestrate".into());
        } else {
            cmd_args.push("server".into());
        }

        if let Some(p) = port {
            match *name {
                "beardog" | "songbird" | "biomeos" => {
                    cmd_args.extend(["--port".into(), p.to_string()]);
                }
                _ => {
                    cmd_args.extend(["--tcp-port".into(), p.to_string()]);
                }
            }
        }

        if let Some(ref fid) = args.family_id {
            if *name != "barracuda" {
                cmd_args.extend(["--family-id".into(), fid.clone()]);
            }
        }

        let log_file = PathBuf::from(format!("/tmp/{name}.log"));
        let log = std::fs::File::create(&log_file).context("creating log")?;
        let mut cmd = std::process::Command::new(&bin_path);
        cmd.args(&cmd_args);
        if *name == "barracuda" {
            if let Some(ref fid) = args.family_id {
                cmd.env("BARRACUDA_FAMILY_ID", fid);
            }
        }
        let child = cmd
            .stdout(log.try_clone()?)
            .stderr(log)
            .spawn()
            .with_context(|| format!("starting {name}"))?;

        println!("  [{name}] STARTED  PID {} port {:?}", child.id(), port);
        launched += 1;

        // Brief delay between primals for dependency ordering
        std::thread::sleep(std::time::Duration::from_millis(200));
    }

    println!();

    let symlinks = create_capability_symlinks(args.family_id.as_deref());
    if symlinks > 0 {
        println!("Capability symlinks: {symlinks} created");
    }

    println!("Summary: {launched} launched, {skipped} skipped");

    Ok(())
}

/// Capability symlinks let primals resolve peers by role instead of name.
///
/// Mapping (from PRIMAL_IPC_PROTOCOL):
///   security.sock      → beardog-{family}.sock  (or beardog.sock)
///   discovery.sock      → songbird.sock
///   orchestration.sock  → songbird.sock
fn create_capability_symlinks(family_id: Option<&str>) -> u32 {
    let socket_dir = resolve_socket_dir();
    let Some(dir) = socket_dir else { return 0 };

    if !dir.exists() && std::fs::create_dir_all(&dir).is_err() {
        return 0;
    }

    let beardog_sock = if let Some(fid) = family_id {
        format!("beardog-{fid}.sock")
    } else {
        "beardog.sock".to_string()
    };

    let links: &[(&str, &str)] = &[
        ("security.sock", &beardog_sock),
        ("discovery.sock", "songbird.sock"),
        ("orchestration.sock", "songbird.sock"),
    ];

    let mut created = 0u32;
    for (capability, target) in links {
        let link_path = dir.join(capability);
        let target_path = dir.join(target);

        if link_path.exists() || link_path.symlink_metadata().is_ok() {
            let _ = std::fs::remove_file(&link_path);
        }

        if !target_path.exists() {
            println!("  [symlink] SKIP  {capability} → {target} (target not found)");
            continue;
        }

        match std::os::unix::fs::symlink(target, &link_path) {
            Ok(()) => {
                println!("  [symlink] OK    {capability} → {target}");
                created += 1;
            }
            Err(e) => {
                println!("  [symlink] FAIL  {capability} → {target}: {e}");
            }
        }
    }

    created
}

fn resolve_socket_dir() -> Option<PathBuf> {
    if let Ok(dir) = std::env::var("BIOMEOS_SOCKET_DIR") {
        return Some(PathBuf::from(dir));
    }
    if let Ok(xdg) = std::env::var("XDG_RUNTIME_DIR") {
        return Some(PathBuf::from(xdg).join("biomeos"));
    }
    None
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
