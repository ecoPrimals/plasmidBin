// SPDX-License-Identifier: AGPL-3.0-or-later

use anyhow::Result;
use clap::Args;
use plasmidbin_types::{Report, checksums, manifest, ports, provenance, sources};
use std::path::{Path, PathBuf};

#[derive(Args)]
pub struct ValidateArgs {
    /// plasmidBin root directory (default: current directory)
    #[arg(default_value = ".")]
    root: PathBuf,

    /// Also check shell script syntax with bash -n
    #[arg(long, default_value_t = true)]
    check_scripts: bool,
}

pub fn run(args: ValidateArgs) -> Result<()> {
    let root = &args.root;

    if !root.join("manifest.toml").exists() {
        anyhow::bail!("no manifest.toml found in {}", root.display());
    }

    let mut total = Report::default();

    println!("=== manifest.toml ===");
    let m = manifest::validate(root);
    total.merge(&m.report);

    println!("\n=== checksums.toml ===");
    let c = checksums::validate(root, &m.primal_ids);
    total.merge(&c.report);

    println!("\n=== ports.env ===");
    let p = ports::validate(root);
    total.merge(&p.report);

    println!("\n=== sources.toml ===");
    let s = sources::validate(root, &m.primal_ids);
    total.merge(&s.report);

    println!("\n=== provenance.toml ===");
    let prov = provenance::validate(root);
    total.merge(&prov);

    println!("\n=== Cross-validation ===");
    cross_validate(&m, &c, &s, &p, &mut total);

    if args.check_scripts {
        println!("\n=== Shell script syntax ===");
        check_shell_scripts(root, &mut total);
    }

    println!("\n=== Summary ===");
    println!("  {total}");

    if total.failed > 0 {
        anyhow::bail!("{} validation failures", total.failed);
    }
    Ok(())
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

    let missing_cksum: Vec<_> = m.difference(c).collect();
    if missing_cksum.is_empty() {
        report.pass("all manifest primals have checksum entries");
    } else {
        // Warn, not fail — primals can exist in manifest before first binary ships
        println!("  WARN: manifest primals without checksums (not yet shipped): {}", fmt_ids(&missing_cksum));
    }

    let extra_cksum: Vec<_> = c.difference(m).collect();
    if extra_cksum.is_empty() {
        report.pass("all checksum entries map to manifest primals");
    } else {
        report.fail(&format!(
            "checksum entries without manifest primals: {}",
            fmt_ids(&extra_cksum)
        ));
    }

    let missing_sources: Vec<_> = m.difference(s).collect();
    if missing_sources.is_empty() {
        report.pass("all manifest primals have source entries");
    } else {
        println!("  WARN: manifest primals without source entries (not yet registered): {}", fmt_ids(&missing_sources));
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

fn check_shell_scripts(root: &Path, report: &mut Report) {
    let patterns = [root.join("*.sh"), root.join("membrane/*.sh")];
    let mut checked = 0;

    for pattern in &patterns {
        let glob_str = pattern.to_string_lossy();
        let entries: Vec<_> = glob_files(&glob_str);
        for path in entries {
            let output = std::process::Command::new("bash")
                .arg("-n")
                .arg(&path)
                .output();
            match output {
                Ok(o) if o.status.success() => {
                    report.pass(&format!("{}", path.display()));
                    checked += 1;
                }
                Ok(o) => {
                    let stderr = String::from_utf8_lossy(&o.stderr);
                    report.fail(&format!("{}: {}", path.display(), stderr.trim()));
                }
                Err(e) => {
                    report.fail(&format!("{}: bash -n failed: {e}", path.display()));
                }
            }
        }
    }

    if checked > 0 {
        report.pass(&format!("{checked} shell scripts pass syntax check"));
    }
}

fn glob_files(pattern: &str) -> Vec<PathBuf> {
    let mut results = Vec::new();
    let dir = std::path::Path::new(pattern)
        .parent()
        .unwrap_or(std::path::Path::new("."));
    let file_pattern = std::path::Path::new(pattern)
        .file_name()
        .map(|f| f.to_string_lossy().to_string())
        .unwrap_or_default();

    if let Ok(entries) = std::fs::read_dir(dir) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            let dominated = if file_pattern == "*.sh" {
                name.ends_with(".sh")
            } else {
                name == file_pattern
            };
            if dominated {
                results.push(entry.path());
            }
        }
    }
    results.sort();
    results
}

fn fmt_ids<S: std::fmt::Display>(ids: &[S]) -> String {
    ids.iter()
        .map(std::string::ToString::to_string)
        .collect::<Vec<_>>()
        .join(", ")
}
