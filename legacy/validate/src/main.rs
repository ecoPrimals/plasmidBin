// SPDX-License-Identifier: AGPL-3.0-or-later

//! `plasmidbin-validate` — typed validation for plasmidBin metadata.
//!
//! Parses and cross-validates manifest.toml, checksums.toml, ports.env,
//! and sources.toml using serde-derived typed structs instead of ad-hoc
//! string parsing. Replaces legacy bash grep/sed validation with structured
//! Rust validation that catches drift between metadata files.

#![forbid(unsafe_code)]

mod checksums;
mod manifest;
mod ports;
mod sources;
mod types;

use std::path::PathBuf;
use std::process::ExitCode;
use types::Report;

fn main() -> ExitCode {
    let root = std::env::args()
        .nth(1)
        .map_or_else(|| PathBuf::from("."), PathBuf::from);

    if !root.join("manifest.toml").exists() {
        eprintln!("ERROR: no manifest.toml found in {}", root.display());
        eprintln!("Usage: plasmidbin-validate [PLASMIDBIN_ROOT]");
        return ExitCode::from(2);
    }

    let mut total = Report::default();

    println!("=== manifest.toml ===");
    let manifest = manifest::validate(&root);
    total.merge(&manifest.report);

    println!("\n=== checksums.toml ===");
    let cksum = checksums::validate(&root, &manifest.primal_ids);
    total.merge(&cksum.report);

    println!("\n=== ports.env ===");
    let port = ports::validate(&root);
    total.merge(&port.report);

    println!("\n=== sources.toml ===");
    let src = sources::validate(&root, &manifest.primal_ids);
    total.merge(&src.report);

    println!("\n=== Cross-validation ===");
    cross_validate(&manifest, &cksum, &src, &port, &mut total);

    println!("\n=== Summary ===");
    println!("  {total}");

    if total.failed > 0 {
        ExitCode::from(1)
    } else {
        ExitCode::from(0)
    }
}

fn cross_validate(
    manifest: &manifest::ManifestReport,
    cksum: &checksums::ChecksumReport,
    src: &sources::SourcesReport,
    ports: &ports::PortsReport,
    report: &mut Report,
) {
    let m = &manifest.primal_ids;
    let c = &cksum.primal_ids;
    let s = &src.source_ids;

    let in_manifest_not_checksums: Vec<_> = m.difference(c).collect();
    if in_manifest_not_checksums.is_empty() {
        report.pass("all manifest primals have checksum entries");
    } else {
        report.fail(&format!(
            "manifest primals without checksums: {}",
            fmt_ids(&in_manifest_not_checksums)
        ));
    }

    let in_checksums_not_manifest: Vec<_> = c.difference(m).collect();
    if in_checksums_not_manifest.is_empty() {
        report.pass("all checksum entries map to manifest primals");
    } else {
        report.fail(&format!(
            "checksum entries without manifest primals: {}",
            fmt_ids(&in_checksums_not_manifest)
        ));
    }

    let primal_sources_missing: Vec<_> = m.difference(s).collect();
    if primal_sources_missing.is_empty() {
        report.pass("all manifest primals have source entries");
    } else {
        report.fail(&format!(
            "manifest primals without source entries: {}",
            fmt_ids(&primal_sources_missing)
        ));
    }

    for (id, port_num) in &ports.port_map {
        if m.contains(id) || manifest.spring_ids.contains(id) {
            continue;
        }
        if ["ludospring", "esotericwebb"].contains(&id.as_str()) {
            continue;
        }
        report.fail(&format!("port assigned for '{id}' (:{port_num}) but not in manifest"));
    }
}

fn fmt_ids<S: std::fmt::Display>(ids: &[S]) -> String {
    ids.iter()
        .map(std::string::ToString::to_string)
        .collect::<Vec<_>>()
        .join(", ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validate_repo_root() {
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..");
        if !root.join("manifest.toml").exists() {
            return;
        }

        let manifest = manifest::validate(&root);
        assert!(
            manifest.report.failed == 0,
            "manifest validation failures: {} failed",
            manifest.report.failed
        );
        assert!(
            manifest.primal_ids.len() >= types::MIN_PRIMALS,
            "expected >= {} primals, found {}",
            types::MIN_PRIMALS,
            manifest.primal_ids.len()
        );

        let cksum = checksums::validate(&root, &manifest.primal_ids);
        assert!(cksum.report.failed == 0, "checksum validation failures");

        let port = ports::validate(&root);
        assert!(port.report.failed == 0, "port validation failures");
        assert!(
            port.port_count >= types::MIN_PRIMALS,
            "expected >= {} port assignments",
            types::MIN_PRIMALS
        );

        let src = sources::validate(&root, &manifest.primal_ids);
        assert!(src.report.failed == 0, "source validation failures");
    }
}
