// SPDX-License-Identifier: AGPL-3.0-or-later

//! `plasmidbin doctor` — health check for plasmidBin installation.

use anyhow::{Result, bail};
use clap::Args;
use plasmidbin_types::arch::Arch;
use plasmidbin_types::checksums::ChecksumsFile;
use plasmidbin_types::KNOWN_PRIMALS;
use std::path::{Path, PathBuf};

#[derive(Args)]
pub struct DoctorArgs {
    /// Skip checksum verification
    #[arg(long)]
    quick: bool,

    /// plasmidBin root directory
    #[arg(long, default_value = ".")]
    root: PathBuf,
}

struct Counters {
    pass: u32,
    warn: u32,
    fail: u32,
}

impl Counters {
    fn new() -> Self { Self { pass: 0, warn: 0, fail: 0 } }

    fn check(&mut self, label: &str, status: &str, detail: &str) {
        match status {
            "pass" => { self.pass += 1; print!("  OK   {label}"); }
            "warn" => { self.warn += 1; print!("  WARN {label}"); }
            _      => { self.fail += 1; print!("  FAIL {label}"); }
        }
        if !detail.is_empty() { println!("  ({detail})"); } else { println!(); }
    }
}

pub fn run(args: DoctorArgs) -> Result<()> {
    let root = &args.root;
    let mut c = Counters::new();

    println!("plasmidBin doctor\n");

    println!("=== Prerequisites ===");
    check_prerequisite(&mut c, "b3sum", false);
    check_prerequisite(&mut c, "curl", false);
    check_prerequisite(&mut c, "gh", true);
    check_prerequisite(&mut c, "strip", true);

    println!("\n=== Metadata ===");
    for f in &["manifest.toml", "sources.toml", "checksums.toml", "ports.env"] {
        if root.join(f).exists() {
            c.check(f, "pass", "");
        } else {
            c.check(f, "fail", "missing");
        }
    }

    println!("\n=== Binary Inventory (x86_64) ===");
    let mut x86_count = 0u32;
    let mut x86_ecobin = 0u32;
    for name in KNOWN_PRIMALS {
        let bin = resolve_binary(root, name);
        match bin {
            Some(path) => {
                x86_count += 1;
                let size = human_size(std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0));
                let is_elf = is_static_elf(&path);
                if is_elf {
                    c.check(name, "pass", &format!("{size}, static"));
                    x86_ecobin += 1;
                } else {
                    c.check(name, "warn", &format!("{size}, dynamic or unknown"));
                }
            }
            None => c.check(name, "fail", "missing"),
        }
    }

    if !args.quick {
        let checksums = ChecksumsFile::load(root).ok();
        if let Some(ref ck) = checksums {
            println!("\n=== Checksum Verification ===");
            let arch = Arch::detect().ok();
            if let Some(arch) = arch {
                for name in KNOWN_PRIMALS {
                    let bin = resolve_binary(root, name);
                    let Some(bin_path) = bin else { continue };
                    if let Some(expected) = ck.get_hash(name, arch.triple()) {
                        let data = std::fs::read(&bin_path).unwrap_or_default();
                        let actual = blake3::hash(&data).to_hex().to_string();
                        if actual == expected {
                            c.check(&format!("{name} checksum"), "pass", "");
                        } else {
                            c.check(&format!("{name} checksum"), "fail", "mismatch");
                        }
                    } else {
                        c.check(&format!("{name} checksum"), "warn", "no entry");
                    }
                }
            }
        }
    }

    println!("\n=== Stale Socket Detection ===");
    check_stale_sockets(&mut c);

    println!("\n=== Summary ===");
    println!("  Pass: {}", c.pass);
    println!("  Warn: {}", c.warn);
    println!("  Fail: {}", c.fail);
    println!("  x86_64 primals: {x86_count} binaries ({x86_ecobin} ecoBin)");

    if c.fail > 0 { bail!("plasmidBin has issues that need attention"); }
    Ok(())
}

fn check_prerequisite(c: &mut Counters, name: &str, optional: bool) {
    let found = std::process::Command::new("which")
        .arg(name)
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false);
    if found {
        c.check(name, "pass", "");
    } else if optional {
        c.check(name, "warn", "optional");
    } else {
        c.check(name, "fail", "required");
    }
}

fn resolve_binary(root: &Path, name: &str) -> Option<PathBuf> {
    let arch = Arch::detect().ok()?;
    let triple_path = root.join("primals").join(arch.triple()).join(name);
    if triple_path.exists() { return Some(triple_path); }
    let flat_path = root.join("primals").join(name);
    if flat_path.exists() { return Some(flat_path); }
    None
}

fn is_static_elf(path: &Path) -> bool {
    let Ok(bytes) = std::fs::read(path) else { return false };
    bytes.len() >= 4 && bytes[..4] == [0x7f, b'E', b'L', b'F']
}

fn check_stale_sockets(c: &mut Counters) {
    let uid = read_uid();
    let dirs = [
        format!("/run/user/{uid}/biomeos"),
        format!("/run/user/{uid}/ecoprimals"),
        "/tmp/biomeos".to_string(),
    ];
    let mut live = 0u32;
    let mut stale = 0u32;

    for dir in &dirs {
        let Ok(entries) = std::fs::read_dir(dir) else { continue };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().is_some_and(|e| e == "sock") {
                #[cfg(unix)]
                {
                    use std::os::unix::net::UnixStream;
                    if UnixStream::connect(&path).is_ok() {
                        live += 1;
                    } else {
                        stale += 1;
                        c.check(&path.display().to_string(), "warn", "stale socket");
                    }
                }
            }
        }
    }

    if stale == 0 {
        c.check("Socket health", "pass", &format!("{live} live, 0 stale"));
    }
}

fn read_uid() -> u32 {
    std::fs::read_to_string("/proc/self/status")
        .ok()
        .and_then(|s| {
            s.lines()
                .find(|l| l.starts_with("Uid:"))
                .and_then(|l| l.split_whitespace().nth(1))
                .and_then(|v| v.parse().ok())
        })
        .unwrap_or(1000)
}

fn human_size(bytes: u64) -> String {
    if bytes >= 1_048_576 { format!("{:.1}M", bytes as f64 / 1_048_576.0) }
    else if bytes >= 1024 { format!("{:.0}K", bytes as f64 / 1024.0) }
    else { format!("{bytes}B") }
}
