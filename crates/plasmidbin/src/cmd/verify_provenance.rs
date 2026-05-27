// SPDX-License-Identifier: AGPL-3.0-or-later

//! `plasmidbin verify-provenance` — verify the provenance chain for harvested binaries.
//!
//! Checks:
//! 1. provenance_hash matches recomputed composite from stored fields
//! 2. content_hash matches the corresponding checksums.toml entry
//! 3. source_commit exists in the repo (when git is available)
//! 4. braid_id resolves via sweetGrass UDS (when available)

use anyhow::Result;
use clap::Args;
use plasmidbin_types::checksums::ChecksumsFile;
use plasmidbin_types::provenance::{ProvenanceFile, compute_provenance_hash};
use std::path::PathBuf;

#[derive(Args)]
pub struct VerifyProvenanceArgs {
    /// plasmidBin root directory (default: current directory)
    #[arg(default_value = ".")]
    root: PathBuf,

    /// Only verify this primal
    #[arg(long)]
    primal: Option<String>,

    /// Also check that source_commit exists in the upstream repo (requires network)
    #[arg(long)]
    check_commits: bool,

    /// Also verify braid_id resolves via sweetGrass UDS
    #[arg(long)]
    check_braids: bool,
}

pub fn run(args: VerifyProvenanceArgs) -> Result<()> {
    let root = &args.root;

    let provenance = ProvenanceFile::load(root)
        .map_err(|e| anyhow::anyhow!(e))?;

    if provenance.primals.is_empty() {
        println!("provenance.toml is empty or not present — nothing to verify");
        return Ok(());
    }

    let checksums = ChecksumsFile::load(root).ok();

    let mut passed = 0u32;
    let mut failed = 0u32;
    let mut warnings = 0u32;

    println!("plasmidBin verify-provenance");
    println!();

    for (primal_id, arches) in &provenance.primals {
        if let Some(ref filter) = args.primal {
            if primal_id != filter { continue; }
        }

        for (triple, entry) in arches {
            let label = format!("{primal_id}/{triple}");

            // Check 1: recompute provenance_hash
            let recomputed = compute_provenance_hash(
                &entry.content_hash,
                &entry.source_commit,
                &entry.build_timestamp,
                &entry.rustc_version,
                &entry.target,
            );
            if recomputed == entry.provenance_hash {
                println!("  [{label}] PASS  provenance_hash matches composite");
                passed += 1;
            } else {
                println!(
                    "  [{label}] FAIL  provenance_hash mismatch: stored={}… recomputed={}…",
                    &entry.provenance_hash[..16.min(entry.provenance_hash.len())],
                    &recomputed[..16.min(recomputed.len())],
                );
                failed += 1;
            }

            // Check 2: content_hash matches checksums.toml
            if let Some(ref ck) = checksums {
                if let Some(ck_hash) = ck.get_hash(primal_id, triple) {
                    if ck_hash == entry.content_hash {
                        println!("  [{label}] PASS  content_hash matches checksums.toml");
                        passed += 1;
                    } else {
                        println!(
                            "  [{label}] FAIL  content_hash mismatch: provenance={}… checksums={}…",
                            &entry.content_hash[..16.min(entry.content_hash.len())],
                            &ck_hash[..16.min(ck_hash.len())],
                        );
                        failed += 1;
                    }
                } else {
                    println!("  [{label}] WARN  no checksums.toml entry (not yet harvested for this triple?)");
                    warnings += 1;
                }
            }

            // Check 3: source_commit exists (optional, requires gh CLI)
            if args.check_commits && !entry.source_repo.is_empty() {
                match verify_commit_exists(&entry.source_repo, &entry.source_commit) {
                    CommitCheck::Exists => {
                        println!("  [{label}] PASS  source_commit exists in {}", entry.source_repo);
                        passed += 1;
                    }
                    CommitCheck::NotFound => {
                        println!("  [{label}] FAIL  source_commit {} not found in {}", &entry.source_commit[..12.min(entry.source_commit.len())], entry.source_repo);
                        failed += 1;
                    }
                    CommitCheck::Unavailable => {
                        println!("  [{label}] WARN  cannot verify source_commit (network/auth)");
                        warnings += 1;
                    }
                }
            }

            // Check 4: braid_id resolves (optional, requires sweetGrass UDS)
            if args.check_braids {
                if let Some(ref braid_id) = entry.braid_id {
                    match verify_braid(braid_id) {
                        BraidCheck::Valid => {
                            println!("  [{label}] PASS  braid_id resolves: {}", &braid_id[..braid_id.len().min(40)]);
                            passed += 1;
                        }
                        BraidCheck::NotFound => {
                            println!("  [{label}] FAIL  braid_id not found: {braid_id}");
                            failed += 1;
                        }
                        BraidCheck::Unavailable => {
                            println!("  [{label}] WARN  sweetGrass unavailable, cannot verify braid");
                            warnings += 1;
                        }
                    }
                } else {
                    println!("  [{label}] WARN  no braid_id recorded (sweetGrass was offline during harvest?)");
                    warnings += 1;
                }
            }
        }
    }

    println!();
    println!("Summary: {passed} passed, {failed} failed, {warnings} warnings");

    if failed > 0 {
        anyhow::bail!("{failed} provenance verification failures");
    }
    Ok(())
}

enum CommitCheck {
    Exists,
    NotFound,
    Unavailable,
}

fn verify_commit_exists(repo: &str, commit: &str) -> CommitCheck {
    let output = std::process::Command::new("gh")
        .args(["api", &format!("repos/{repo}/commits/{commit}"), "--jq", ".sha"])
        .output();

    match output {
        Ok(o) if o.status.success() => {
            let sha = String::from_utf8_lossy(&o.stdout).trim().to_string();
            if sha.starts_with(commit) || commit.starts_with(&sha) {
                CommitCheck::Exists
            } else {
                CommitCheck::NotFound
            }
        }
        Ok(_) => CommitCheck::NotFound,
        Err(_) => CommitCheck::Unavailable,
    }
}

enum BraidCheck {
    Valid,
    NotFound,
    Unavailable,
}

fn verify_braid(braid_id: &str) -> BraidCheck {
    let uid = super::current_uid();
    let socket_paths = [
        std::env::var("SWEETGRASS_SOCKET").unwrap_or_default(),
        format!("/run/user/{uid}/ecoprimals/sweetgrass.sock"),
    ];

    let socket = socket_paths.iter()
        .map(std::path::PathBuf::from)
        .find(|p| p.exists());

    let Some(socket) = socket else {
        return BraidCheck::Unavailable;
    };

    let request = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "braid.get",
        "params": { "id": braid_id }
    });

    use std::io::{Read, Write};
    use std::os::unix::net::UnixStream;
    use std::time::Duration;

    let stream = match UnixStream::connect(&socket) {
        Ok(s) => s,
        Err(_) => return BraidCheck::Unavailable,
    };
    let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(5)));

    let payload = match serde_json::to_string(&request) {
        Ok(p) => p + "\n",
        Err(_) => return BraidCheck::Unavailable,
    };

    let mut stream = stream;
    if stream.write_all(payload.as_bytes()).is_err() {
        return BraidCheck::Unavailable;
    }
    let _ = stream.flush();

    let mut buf = Vec::new();
    let mut tmp = [0u8; 4096];
    loop {
        match stream.read(&mut tmp) {
            Ok(0) => break,
            Ok(n) => {
                buf.extend_from_slice(&tmp[..n]);
                if buf.contains(&b'\n') { break; }
            }
            Err(_) => break,
        }
    }

    let text = String::from_utf8_lossy(&buf);
    match serde_json::from_str::<serde_json::Value>(text.trim()) {
        Ok(resp) => {
            if resp.get("result").is_some() {
                BraidCheck::Valid
            } else {
                BraidCheck::NotFound
            }
        }
        Err(_) => BraidCheck::Unavailable,
    }
}
