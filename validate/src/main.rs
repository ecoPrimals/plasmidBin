// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! plasmidbin-validate — typed validation for plasmidBin metadata.
//!
//! Parses and cross-validates manifest.toml, checksums.toml, ports.env,
//! and sources.toml. Replaces ad-hoc bash grep/sed parsing with structured
//! Rust validation that catches drift between metadata files.

mod checksums;
mod manifest;
mod ports;
mod sources;

use std::path::PathBuf;
use std::process::ExitCode;

fn main() -> ExitCode {
    let root = std::env::args()
        .nth(1)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."));

    if !root.join("manifest.toml").exists() {
        eprintln!("ERROR: no manifest.toml found in {}", root.display());
        eprintln!("Usage: plasmidbin-validate [PLASMIDBIN_ROOT]");
        return ExitCode::from(2);
    }

    let mut total_passed = 0usize;
    let mut total_failed = 0usize;

    // Phase 1: manifest.toml
    println!("=== manifest.toml ===");
    let manifest = manifest::validate(&root);
    total_passed += manifest.passed;
    total_failed += manifest.failed;

    // Phase 2: checksums.toml
    println!("\n=== checksums.toml ===");
    let cksum = checksums::validate(&root, &manifest.primal_ids);
    total_passed += cksum.passed;
    total_failed += cksum.failed;

    // Phase 3: ports.env
    println!("\n=== ports.env ===");
    let port = ports::validate(&root);
    total_passed += port.passed;
    total_failed += port.failed;

    // Phase 4: sources.toml
    println!("\n=== sources.toml ===");
    let src = sources::validate(&root, &manifest.primal_ids);
    total_passed += src.passed;
    total_failed += src.failed;

    // Phase 5: cross-validation
    println!("\n=== Cross-validation ===");
    let manifest_set = &manifest.primal_ids;
    let checksum_set = &cksum.primal_ids;
    let source_set = &src.source_ids;

    let in_manifest_not_checksums: Vec<_> = manifest_set.difference(checksum_set).collect();
    let in_checksums_not_manifest: Vec<_> = checksum_set.difference(manifest_set).collect();

    if in_manifest_not_checksums.is_empty() {
        total_passed += 1;
        println!("  PASS: all manifest primals have checksum entries");
    } else {
        eprintln!("  WARN: manifest primals without checksums: {:?}", in_manifest_not_checksums);
    }

    if in_checksums_not_manifest.is_empty() {
        total_passed += 1;
        println!("  PASS: all checksum entries have manifest primals");
    } else {
        eprintln!("  WARN: checksum entries without manifest primals: {:?}", in_checksums_not_manifest);
    }

    // Source entries may include non-primals (springs, products)
    let primal_sources: Vec<_> = manifest_set.difference(source_set).collect();
    if primal_sources.is_empty() {
        total_passed += 1;
        println!("  PASS: all manifest primals have source entries");
    } else {
        eprintln!("  WARN: manifest primals without source entries: {:?}", primal_sources);
    }

    // Summary
    println!("\n=== Summary ===");
    println!("  {} passed, {} failed", total_passed, total_failed);

    if total_failed > 0 {
        ExitCode::from(1)
    } else {
        ExitCode::from(0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validate_repo_root() {
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..");
        if !root.join("manifest.toml").exists() {
            return; // skip if not in plasmidBin tree
        }

        let manifest = manifest::validate(&root);
        assert!(manifest.failed == 0, "manifest validation failures");
        assert!(manifest.primal_ids.len() >= 13, "expected >= 13 primals");

        let cksum = checksums::validate(&root, &manifest.primal_ids);
        assert!(cksum.failed == 0, "checksum validation failures");

        let port = ports::validate(&root);
        assert!(port.failed == 0, "port validation failures");
        assert!(port.port_count >= 13, "expected >= 13 port assignments");

        let src = sources::validate(&root, &manifest.primal_ids);
        assert!(src.failed == 0, "source validation failures");
    }
}
