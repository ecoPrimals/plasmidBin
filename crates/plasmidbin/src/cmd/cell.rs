// SPDX-License-Identifier: AGPL-3.0-or-later

//! `plasmidbin cell` — deploy cell graphs from `cells/*.toml`.

use anyhow::{Context, Result, bail};
use clap::Args;
use plasmidbin_types::arch::Arch;
use serde::Deserialize;
use std::collections::BTreeMap;
use std::path::PathBuf;

#[derive(Args)]
pub struct CellArgs {
    /// Cell name (e.g., hotspring, neuralspring)
    cell: String,

    /// Family identifier
    #[arg(long)]
    family_id: Option<String>,

    /// plasmidBin root directory
    #[arg(long, default_value = ".")]
    root: PathBuf,
}

#[derive(Debug, Deserialize)]
struct CellGraph {
    cell: CellMeta,
    #[serde(default)]
    primals: BTreeMap<String, CellPrimal>,
}

#[derive(Debug, Deserialize)]
struct CellMeta {
    name: String,
    spring: String,
    #[serde(default)]
    description: Option<String>,
}

#[derive(Debug, Deserialize)]
struct CellPrimal {
    #[serde(default)]
    required: Option<bool>,
    #[serde(default)]
    tcp_port: Option<u16>,
    #[serde(default)]
    args: Vec<String>,
}

pub fn run(args: CellArgs) -> Result<()> {
    let root = &args.root;
    let arch = Arch::detect().map_err(|e| anyhow::anyhow!(e))?;

    let cell_file = root.join("cells").join(format!("{}_cell.toml", args.cell));
    if !cell_file.exists() {
        bail!("cell graph not found: {}", cell_file.display());
    }

    let content = std::fs::read_to_string(&cell_file)
        .context("reading cell graph")?;
    let graph: CellGraph = toml::from_str(&content)
        .context("parsing cell graph")?;

    println!("plasmidBin cell — {}", graph.cell.name);
    println!("Spring: {}", graph.cell.spring);
    if let Some(ref desc) = graph.cell.description {
        println!("  {desc}");
    }
    println!();

    let mut launched = 0u32;
    let mut skipped = 0u32;

    for (name, primal_cfg) in &graph.primals {
        let bin = resolve_binary(root, name, arch);
        let Some(bin_path) = bin else {
            if primal_cfg.required.unwrap_or(true) {
                println!("  [{name}] FAIL  required binary not found");
            } else {
                println!("  [{name}] SKIP  optional, not present");
            }
            skipped += 1;
            continue;
        };

        if is_running(name) {
            println!("  [{name}] RUNNING  (already up)");
            skipped += 1;
            continue;
        }

        let mut cmd_args: Vec<String> = vec!["server".into()];
        if let Some(port) = primal_cfg.tcp_port {
            cmd_args.extend(["--tcp-port".into(), port.to_string()]);
        }
        cmd_args.extend(primal_cfg.args.iter().cloned());

        if let Some(ref fid) = args.family_id {
            cmd_args.extend(["--family-id".into(), fid.clone()]);
        }

        let log = PathBuf::from(format!("/tmp/{}-{}.log", name, args.cell));
        let log_file = std::fs::File::create(&log)?;
        let child = std::process::Command::new(&bin_path)
            .args(&cmd_args)
            .stdout(log_file.try_clone()?)
            .stderr(log_file)
            .spawn()
            .with_context(|| format!("starting {name}"))?;

        println!("  [{name}] STARTED  PID {}", child.id());
        launched += 1;
        std::thread::sleep(std::time::Duration::from_millis(200));
    }

    println!();
    println!("Cell {}: {launched} launched, {skipped} skipped", args.cell);
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
