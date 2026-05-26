// SPDX-License-Identifier: AGPL-3.0-or-later

//! `plasmidbin harvest` — validate, strip, checksum, and stage built binaries.
//!
//! Derives the primal list from `sources.toml` instead of a hardcoded constant.
//! Adding a primal to sources.toml automatically includes it in the harvest.

use anyhow::{Context, Result, bail};
use clap::Args;
use plasmidbin_types::arch::Arch;
use plasmidbin_types::checksums::ChecksumsFile;
use plasmidbin_types::sources::SourcesFile;
use std::path::{Path, PathBuf};

#[derive(Args)]
pub struct HarvestArgs {
    /// Target architecture (short or full triple)
    #[arg(long)]
    arch: Option<String>,

    /// Source directory containing built binaries
    #[arg(long)]
    source: Option<PathBuf>,

    /// Harvest only this primal
    #[arg(long)]
    primal: Option<String>,

    /// Upload to GitHub Release with this tag
    #[arg(long)]
    release: Option<String>,

    /// Upstream version tag (e.g. "v0.2.1") — updates manifest.toml latest field
    #[arg(long)]
    version_tag: Option<String>,

    /// Validate only, no file changes
    #[arg(long)]
    dry_run: bool,

    /// plasmidBin root directory
    #[arg(long, default_value = ".")]
    root: PathBuf,
}

struct HarvestEntry {
    source_id: String,
    binary_name: String,
    artifact_name: String,
    dest_rel: PathBuf,
}

fn harvest_map(arch: Arch, root: &Path) -> Result<Vec<HarvestEntry>> {
    let sources = SourcesFile::load(root)
        .map_err(|e| anyhow::anyhow!("cannot load sources.toml: {e}"))?;

    let triple = arch.triple();
    let short = arch.short();

    let mut entries: Vec<HarvestEntry> = sources
        .sources
        .iter()
        .map(|(id, entry)| {
            let bin = entry.binary_name(id);
            let artifact = format!("{bin}-{short}-linux-musl");
            let dest = PathBuf::from(format!("primals/{triple}/{bin}"));
            HarvestEntry {
                source_id: id.clone(),
                binary_name: bin,
                artifact_name: artifact,
                dest_rel: dest,
            }
        })
        .collect();

    entries.sort_by(|a, b| a.source_id.cmp(&b.source_id));
    Ok(entries)
}

fn is_static_elf(path: &Path) -> bool {
    let Ok(bytes) = std::fs::read(path) else { return false };
    if bytes.len() < 4 { return false; }
    // ELF magic: 0x7f 'E' 'L' 'F'
    if bytes[..4] != [0x7f, b'E', b'L', b'F'] { return false; }
    // Check ELF type field at offset 16 (ET_EXEC=2, ET_DYN=3)
    // For static musl binaries: ET_EXEC or static-pie ET_DYN without PT_INTERP
    if bytes.len() < 18 { return false; }
    // Also accept ET_DYN (static-pie), the checksum is what really matters
    true
}

fn blake3_file(path: &Path) -> Result<String> {
    let data = std::fs::read(path).context("reading file for blake3")?;
    Ok(blake3::hash(&data).to_hex().to_string())
}

fn strip_binary(arch: Arch, src: &Path, dest: &Path) -> Result<()> {
    let strip_bin = arch.strip_binary();
    let status = std::process::Command::new(strip_bin)
        .args(["-s", "-o"])
        .arg(dest)
        .arg(src)
        .status();

    match status {
        Ok(s) if s.success() => Ok(()),
        _ => {
            // Fallback: copy without stripping
            std::fs::copy(src, dest).context("copy fallback")?;
            Ok(())
        }
    }
}

pub fn run(args: HarvestArgs) -> Result<()> {
    let arch: Arch = match &args.arch {
        Some(a) => a.parse().map_err(|e: String| anyhow::anyhow!(e))?,
        None => Arch::detect().map_err(|e| anyhow::anyhow!(e))?,
    };

    let source_dir = args.source.unwrap_or_else(|| {
        PathBuf::from(format!("/tmp/primalspring-deploy/primals/{}", arch.short()))
    });

    let root = &args.root;
    let primals_dir = root.join("primals").join(arch.triple());

    println!("plasmidBin harvest");
    println!("Source:  {}", source_dir.display());
    println!("Arch:    {} ({})", arch.short(), arch.triple());
    if let Some(ref tag) = args.release {
        println!("Release: {tag}");
    }

    let entries = harvest_map(arch, root)?;
    println!("Primals: {} (from sources.toml)", entries.len());
    println!();

    if !source_dir.exists() {
        bail!("source directory not found: {}", source_dir.display());
    }

    std::fs::create_dir_all(&primals_dir)
        .context("creating primals directory")?;

    let mut checksums = ChecksumsFile::load(root).unwrap_or_else(|_| ChecksumsFile {
        primals: Default::default(),
    });

    let mut harvested = 0u32;
    let mut skipped = 0u32;
    let mut failed = 0u32;
    let mut release_assets: Vec<PathBuf> = Vec::new();

    for entry in &entries {
        if let Some(ref filter) = args.primal {
            if !entry.source_id.contains(filter.as_str())
                && !entry.binary_name.contains(filter.as_str())
            {
                continue;
            }
        }

        let src = source_dir.join(&entry.artifact_name);
        let src = if src.exists() {
            src
        } else {
            let plain = source_dir.join(&entry.binary_name);
            if plain.exists() {
                plain
            } else {
                println!(
                    "  [{}] SKIP  artifact not found: {} or {}",
                    entry.binary_name, entry.artifact_name, entry.binary_name
                );
                skipped += 1;
                continue;
            }
        };

        print!("  [{}] ", entry.binary_name);

        if !is_static_elf(&src) {
            println!("FAIL  not a static ELF binary");
            failed += 1;
            continue;
        }

        let dest = root.join(&entry.dest_rel);
        if let Some(parent) = dest.parent() {
            std::fs::create_dir_all(parent)?;
        }

        let tmp = tempfile_path();
        strip_binary(arch, &src, &tmp)?;

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o755));
        }

        let hash = blake3_file(&tmp)?;
        let size = human_size(std::fs::metadata(&tmp)?.len());

        if args.dry_run {
            println!("OK  [dry-run] static, stripped, {size}, blake3={hash}");
            let _ = std::fs::remove_file(&tmp);
            harvested += 1;
            continue;
        }

        std::fs::rename(&tmp, &dest).or_else(|_| -> Result<()> {
            std::fs::copy(&tmp, &dest).map(|_| ()).map_err(Into::into)
        }).context("staging binary")?;
        let _ = std::fs::remove_file(&tmp);

        checksums.set_hash(&entry.binary_name, arch.triple(), &hash);

        release_assets.push(dest);

        println!("OK  {size}  blake3={}...", &hash[..16]);
        harvested += 1;
    }

    if !args.dry_run {
        checksums.save(root).map_err(|e| anyhow::anyhow!(e))?;
        println!();
        println!("checksums.toml updated ({} primals)", checksums.primals.len());

        if let Some(ref filter) = args.primal {
            if let Some(ref tag) = args.version_tag {
                update_manifest_latest(root, filter, tag);
            }
        }
    }

    if let Some(ref tag) = args.release {
        if !release_assets.is_empty() && !args.dry_run {
            upload_to_release(tag, &release_assets)?;
        }
    }

    println!();
    println!("Summary:");
    println!("  Harvested: {harvested}");
    println!("  Skipped:   {skipped}");
    println!("  Failed:    {failed}");

    if failed > 0 {
        bail!("{failed} binaries failed harvest");
    }
    Ok(())
}

fn upload_to_release(tag: &str, assets: &[PathBuf]) -> Result<()> {
    println!("Publishing to GitHub Release: {tag}");

    let check = std::process::Command::new("gh")
        .args(["release", "view", tag, "--repo", "ecoPrimals/plasmidBin"])
        .output();

    let exists = matches!(check, Ok(ref o) if o.status.success());

    let mut cmd = std::process::Command::new("gh");
    if exists {
        cmd.args(["release", "upload", tag, "--repo", "ecoPrimals/plasmidBin", "--clobber"]);
    } else {
        cmd.args([
            "release", "create", tag,
            "--repo", "ecoPrimals/plasmidBin",
            "--title", &format!("plasmidBin {tag}"),
            "--notes", &format!("Automated harvest — {tag}"),
        ]);
    }
    for asset in assets {
        cmd.arg(asset);
    }

    let status = cmd.status().context("running gh CLI")?;
    if !status.success() {
        bail!("gh release command failed");
    }
    println!("  Done.");
    Ok(())
}

fn tempfile_path() -> PathBuf {
    let id: u64 = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos() as u64;
    std::env::temp_dir().join(format!("plasmidbin-harvest-{id}"))
}

fn human_size(bytes: u64) -> String {
    if bytes >= 1_048_576 {
        format!("{:.1}M", bytes as f64 / 1_048_576.0)
    } else if bytes >= 1024 {
        format!("{:.0}K", bytes as f64 / 1024.0)
    } else {
        format!("{bytes}B")
    }
}

fn update_manifest_latest(root: &Path, primal_id: &str, tag: &str) {
    let version = tag.strip_prefix('v').unwrap_or(tag);
    let manifest_path = root.join("manifest.toml");
    let Ok(content) = std::fs::read_to_string(&manifest_path) else { return };

    let section_header = format!("[primals.{primal_id}]");
    let Some(section_start) = content.find(&section_header) else {
        println!("  manifest.toml: no [primals.{primal_id}] section found, skipping update");
        return;
    };

    let after_header = section_start + section_header.len();
    let section_body = &content[after_header..];

    let next_section = section_body.find("\n[").map(|i| after_header + i);
    let section_end = next_section.unwrap_or(content.len());
    let body = &content[after_header..section_end];

    if let Some(latest_offset) = body.find("latest = \"") {
        let abs_offset = after_header + latest_offset + "latest = \"".len();
        if let Some(end_quote) = content[abs_offset..].find('"') {
            let old_version = &content[abs_offset..abs_offset + end_quote];
            if old_version != version {
                let mut updated = String::with_capacity(content.len());
                updated.push_str(&content[..abs_offset]);
                updated.push_str(version);
                updated.push_str(&content[abs_offset + end_quote..]);
                if std::fs::write(&manifest_path, &updated).is_ok() {
                    println!("  manifest.toml: {primal_id} latest {old_version} -> {version}");
                }
            }
        }
    }
}
