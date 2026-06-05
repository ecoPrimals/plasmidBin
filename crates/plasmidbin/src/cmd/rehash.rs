// SPDX-License-Identifier: AGPL-3.0-or-later

//! `plasmidbin rehash` — recompute BLAKE3 checksums for all local binaries.
//!
//! Reads every binary in `primals/{triple}/` and updates `checksums.toml`
//! in place, preserving non-local triples. Use after local builds when
//! checksums have drifted from the current binaries.

use anyhow::{Result, bail};
use clap::Args;
use plasmidbin_types::arch::Arch;
use plasmidbin_types::checksums::ChecksumsFile;
use std::path::PathBuf;

#[derive(Args)]
pub struct RehashArgs {
    /// Rehash only this primal
    #[arg(long)]
    primal: Option<String>,

    /// Show what would change without writing
    #[arg(long)]
    dry_run: bool,

    /// plasmidBin root directory
    #[arg(long, default_value = ".")]
    root: PathBuf,
}

pub fn run(args: RehashArgs) -> Result<()> {
    let root = &args.root;
    let arch = Arch::detect()?;
    let triple = arch.triple();
    let primals_dir = root.join("primals").join(triple);

    if !primals_dir.exists() {
        bail!("primals directory not found: {}", primals_dir.display());
    }

    println!("plasmidBin rehash");
    println!("Arch: {triple}");
    println!("Source: {}", primals_dir.display());
    println!();

    let mut checksums = ChecksumsFile::load(root).unwrap_or_else(|_| ChecksumsFile {
        primals: Default::default(),
    });

    let mut updated = 0u32;
    let mut unchanged = 0u32;
    let mut added = 0u32;

    let mut entries: Vec<_> = std::fs::read_dir(&primals_dir)?
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().map(|t| t.is_file()).unwrap_or(false))
        .collect();
    entries.sort_by_key(|e| e.file_name());

    for entry in entries {
        let name = entry.file_name().to_string_lossy().to_string();

        if let Some(ref filter) = args.primal {
            if &name != filter {
                continue;
            }
        }

        let path = entry.path();
        let data = std::fs::read(&path)?;
        let new_hash = blake3::hash(&data).to_hex().to_string();

        let hashes = checksums.primals.entry(name.clone()).or_default();
        let old_hash = hashes.get(triple).cloned();

        match old_hash {
            Some(ref old) if old == &new_hash => {
                println!("  [{name}] CURRENT");
                unchanged += 1;
            }
            Some(ref old) => {
                if args.dry_run {
                    println!("  [{name}] WOULD UPDATE  {old:.12}.. -> {new_hash:.12}..");
                } else {
                    hashes.insert(triple.to_owned(), new_hash.clone());
                    println!("  [{name}] UPDATED  {old:.12}.. -> {new_hash:.12}..");
                }
                updated += 1;
            }
            None => {
                if args.dry_run {
                    println!("  [{name}] WOULD ADD  {new_hash:.12}..");
                } else {
                    hashes.insert(triple.to_owned(), new_hash.clone());
                    println!("  [{name}] ADDED  {new_hash:.12}..");
                }
                added += 1;
            }
        }
    }

    println!();
    println!("Summary:");
    println!("  Current:   {unchanged}");
    println!("  Updated:   {updated}");
    println!("  Added:     {added}");

    if !args.dry_run && (updated > 0 || added > 0) {
        checksums.save(root)?;
        println!("\nchecksums.toml written.");
    } else if args.dry_run {
        println!("\n(dry-run — no files modified)");
    }

    Ok(())
}
