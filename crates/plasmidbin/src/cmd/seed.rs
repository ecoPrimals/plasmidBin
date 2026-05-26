// SPDX-License-Identifier: AGPL-3.0-or-later

//! `plasmidbin seed` — Dark Forest seed lifecycle via BearDog crypto.

use anyhow::{Context, Result, bail};
use clap::{Args, Subcommand};
use plasmidbin_types::arch::Arch;
use std::path::PathBuf;

#[derive(Args)]
pub struct SeedArgs {
    #[command(subcommand)]
    action: SeedAction,
}

#[derive(Subcommand)]
enum SeedAction {
    /// Generate a new family seed
    Generate(SeedGenerateArgs),
    /// Verify an existing seed
    Verify(SeedVerifyArgs),
    /// Export seed for remote gate
    Export(SeedExportArgs),
}

#[derive(Args)]
struct SeedGenerateArgs {
    /// Family name
    #[arg(long)]
    family: String,

    /// Output directory
    #[arg(long, default_value = "~/.config/biomeos/family")]
    output: String,

    /// plasmidBin root directory
    #[arg(long, default_value = ".")]
    root: PathBuf,
}

#[derive(Args)]
struct SeedVerifyArgs {
    /// Seed file to verify
    path: PathBuf,

    /// plasmidBin root directory
    #[arg(long, default_value = ".")]
    root: PathBuf,
}

#[derive(Args)]
struct SeedExportArgs {
    /// Family name
    #[arg(long)]
    family: String,

    /// Export format (base64, hex, file)
    #[arg(long, default_value = "base64")]
    format: String,
}

pub fn run(args: SeedArgs) -> Result<()> {
    match args.action {
        SeedAction::Generate(a) => seed_generate(a),
        SeedAction::Verify(a) => seed_verify(a),
        SeedAction::Export(a) => seed_export(a),
    }
}

fn seed_generate(args: SeedGenerateArgs) -> Result<()> {
    let root = &args.root;
    let arch = Arch::detect().map_err(|e| anyhow::anyhow!(e))?;

    let beardog = root.join("primals").join(arch.triple()).join("beardog");
    if !beardog.exists() {
        let flat = root.join("primals").join("beardog");
        if !flat.exists() {
            bail!("beardog binary not found — required for seed generation");
        }
    }

    let beardog_path = if root.join("primals").join(arch.triple()).join("beardog").exists() {
        root.join("primals").join(arch.triple()).join("beardog")
    } else {
        root.join("primals").join("beardog")
    };

    let output_dir = shellexpand(&args.output);
    std::fs::create_dir_all(&output_dir).context("creating seed directory")?;

    println!("plasmidBin seed generate");
    println!("Family: {}", args.family);
    println!("Output: {output_dir}");
    println!();

    // Generate keypair via beardog
    let status = std::process::Command::new(&beardog_path)
        .args(["crypto", "generate-keypair", "--output", &format!("{}/{}.key", output_dir, args.family)])
        .status()
        .context("beardog crypto generate-keypair")?;

    if !status.success() {
        bail!("beardog keypair generation failed");
    }

    // Generate family seed
    let seed_data = std::fs::read(format!("{}/{}.key", output_dir, args.family))?;
    let seed_hash = blake3::hash(&seed_data).to_hex().to_string();

    let seed_file = format!("{}/{}.seed", output_dir, args.family);
    std::fs::write(&seed_file, &seed_hash).context("writing seed file")?;

    println!("  Keypair: {}/{}.key", output_dir, args.family);
    println!("  Seed:    {seed_file}");
    println!("  Hash:    {}", &seed_hash[..16]);

    Ok(())
}

fn seed_verify(args: SeedVerifyArgs) -> Result<()> {
    if !args.path.exists() {
        bail!("seed file not found: {}", args.path.display());
    }

    let content = std::fs::read_to_string(&args.path)?;
    let hash = content.trim();

    if plasmidbin_types::is_valid_blake3_hex(hash) {
        println!("Seed verified: valid BLAKE3 hash");
        println!("  File: {}", args.path.display());
        println!("  Hash: {}", &hash[..16]);
    } else {
        bail!("invalid seed format (expected 64 lowercase hex chars)");
    }

    Ok(())
}

fn seed_export(args: SeedExportArgs) -> Result<()> {
    let seed_dir = shellexpand("~/.config/biomeos/family");
    let seed_file = format!("{}/{}.seed", seed_dir, args.family);

    if !PathBuf::from(&seed_file).exists() {
        bail!("seed not found: {seed_file}");
    }

    let content = std::fs::read_to_string(&seed_file)?;
    let hash = content.trim();

    match args.format.as_str() {
        "hex" => println!("{hash}"),
        "base64" => {
            let output = std::process::Command::new("base64")
                .arg("-w0")
                .stdin(std::process::Stdio::piped())
                .stdout(std::process::Stdio::piped())
                .spawn()
                .and_then(|mut child| {
                    use std::io::Write;
                    child.stdin.take().unwrap().write_all(hash.as_bytes())?;
                    child.wait_with_output()
                })?;
            println!("{}", String::from_utf8_lossy(&output.stdout));
        }
        "file" => {
            println!("{seed_file}");
        }
        _ => bail!("unsupported format: {}", args.format),
    }

    Ok(())
}

fn shellexpand(path: &str) -> String {
    if path.starts_with("~/") {
        if let Ok(home) = std::env::var("HOME") {
            return format!("{}/{}", home, &path[2..]);
        }
    }
    path.to_string()
}
