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
    "beardog", "skunkbat", "songbird",
    "nestgate", "rhizocrypt", "loamspine", "sweetgrass",
    "toadstool", "barracuda", "coralreef",
    "squirrel", "petaltongue", "biomeos",
];

pub fn run(args: LaunchArgs) -> Result<()> {
    let root = &args.root;
    let arch = Arch::detect().map_err(|e| anyhow::anyhow!(e))?;
    let port_map = ports::load_port_map(root).map_err(|e| anyhow::anyhow!(e))?;
    let compositions = ports::load_compositions(root).map_err(|e| anyhow::anyhow!(e))?;

    let comp_key = format!("COMP_{}", args.composition.to_uppercase());
    let primals: Vec<String> = compositions
        .get(&comp_key)
        .cloned()
        .unwrap_or_else(|| {
            LAUNCH_ORDER.iter().map(|s| s.to_string()).collect()
        });

    println!("plasmidBin launch — {}", args.composition);
    println!("Composition: {} primals", primals.len());
    println!();

    let mut launched = 0u32;
    let mut skipped = 0u32;

    for name in LAUNCH_ORDER {
        if !primals.contains(&name.to_string()) { continue; }

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
    println!("Summary: {launched} launched, {skipped} skipped");

    Ok(())
}

fn resolve_binary(root: &std::path::Path, name: &str, arch: Arch) -> Option<PathBuf> {
    let triple_path = root.join("primals").join(arch.triple()).join(name);
    if triple_path.exists() { return Some(triple_path); }
    let flat_path = root.join("primals").join(name);
    if flat_path.exists() { return Some(flat_path); }
    None
}

fn is_running(name: &str) -> bool {
    std::process::Command::new("pgrep")
        .args(["-x", name])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}
