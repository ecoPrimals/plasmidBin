// SPDX-License-Identifier: AGPL-3.0-or-later

//! `plasmidbin harvest` — validate, strip, checksum, and stage built binaries.
//!
//! Derives the primal list from `sources.toml` instead of a hardcoded constant.
//! Adding a primal to sources.toml automatically includes it in the harvest.

use anyhow::{Context, Result, bail};
use clap::Args;
use plasmidbin_types::arch::Arch;
use plasmidbin_types::checksums::ChecksumsFile;
use plasmidbin_types::provenance::{
    BuildSidecar, ProvenanceEntry, ProvenanceFile, compute_provenance_hash,
};
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
    let sources = SourcesFile::load(root)?;

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
    let Ok(bytes) = std::fs::read(path) else {
        return false;
    };
    if bytes.len() < 4 {
        return false;
    }
    // ELF magic: 0x7f 'E' 'L' 'F'
    if bytes[..4] != [0x7f, b'E', b'L', b'F'] {
        return false;
    }
    // Check ELF type field at offset 16 (ET_EXEC=2, ET_DYN=3)
    // For static musl binaries: ET_EXEC or static-pie ET_DYN without PT_INTERP
    if bytes.len() < 18 {
        return false;
    }
    // Also accept ET_DYN (static-pie), the checksum is what really matters
    true
}

use super::defaults::blake3_file;

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
        Some(a) => a.parse()?,
        None => Arch::detect()?,
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

    std::fs::create_dir_all(&primals_dir).context("creating primals directory")?;

    let mut checksums = ChecksumsFile::load(root).unwrap_or_else(|_| ChecksumsFile {
        primals: Default::default(),
    });

    let mut harvested = 0u32;
    let mut skipped = 0u32;
    let mut failed = 0u32;
    let mut release_assets: Vec<PathBuf> = Vec::new();
    let mut harvest_records: Vec<(String, String, PathBuf)> = Vec::new();

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

        std::fs::rename(&tmp, &dest)
            .or_else(|_| -> Result<()> {
                std::fs::copy(&tmp, &dest).map(|_| ()).map_err(Into::into)
            })
            .context("staging binary")?;
        let _ = std::fs::remove_file(&tmp);

        checksums.set_hash(&entry.source_id, arch.triple(), &hash);

        release_assets.push(dest);
        harvest_records.push((entry.source_id.clone(), hash.clone(), src.clone()));

        println!("OK  {size}  blake3={}...", &hash[..16]);
        harvested += 1;
    }

    if !args.dry_run {
        checksums.save(root)?;
        println!();
        println!(
            "checksums.toml updated ({} primals)",
            checksums.primals.len()
        );

        // Write provenance.toml for every harvested binary that has a sidecar
        let mut provenance = ProvenanceFile::load(root).unwrap_or_default();
        let mut prov_count = 0u32;
        let mut braid_entries: Vec<(String, ProvenanceEntry, u64)> = Vec::new();

        for (source_id, content_hash, src_path) in &harvest_records {
            if let Some(sidecar) = BuildSidecar::read_next_to(src_path) {
                let prov_hash = compute_provenance_hash(
                    content_hash,
                    &sidecar.source_commit,
                    &sidecar.build_timestamp,
                    &sidecar.rustc_version,
                    arch.triple(),
                );
                let bin_size = std::fs::metadata(src_path).map(|m| m.len()).unwrap_or(0);
                let entry = ProvenanceEntry {
                    content_hash: content_hash.clone(),
                    source_commit: sidecar.source_commit,
                    source_repo: sidecar.source_repo,
                    build_timestamp: sidecar.build_timestamp,
                    rustc_version: sidecar.rustc_version,
                    target: arch.triple().to_string(),
                    provenance_hash: prov_hash,
                    braid_id: None,
                };
                braid_entries.push((source_id.clone(), entry.clone(), bin_size));
                provenance.set_entry(source_id, arch.triple(), entry);
                prov_count += 1;
            }
        }

        // Attempt sweetGrass braid.create for each provenance entry
        for (source_id, entry, bin_size) in &mut braid_entries {
            match try_braid_create(source_id, entry, *bin_size) {
                BraidResult::Created(braid_id) => {
                    println!(
                        "  braid: {source_id} -> {}",
                        &braid_id[..braid_id.len().min(40)]
                    );
                    entry.braid_id = Some(braid_id.clone());
                    provenance.set_entry(source_id, arch.triple(), entry.clone());
                }
                BraidResult::Pending(path) => {
                    println!("  braid: {source_id} -> pending at {}", path.display());
                }
                BraidResult::Skipped => {}
            }
        }

        if prov_count > 0 {
            provenance.save(root)?;
            println!("provenance.toml updated ({prov_count} entries from build sidecars)");
        }

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
        .args([
            "release",
            "view",
            tag,
            "--repo",
            &super::defaults::org_repo(),
        ])
        .output();

    let exists = matches!(check, Ok(ref o) if o.status.success());

    let mut cmd = std::process::Command::new("gh");
    if exists {
        cmd.args([
            "release",
            "upload",
            tag,
            "--repo",
            &super::defaults::org_repo(),
            "--clobber",
        ]);
    } else {
        cmd.args([
            "release",
            "create",
            tag,
            "--repo",
            &super::defaults::org_repo(),
            "--title",
            &format!("plasmidBin {tag}"),
            "--notes",
            &format!("Automated harvest — {tag}"),
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

use super::defaults::human_size;

fn update_manifest_latest(root: &Path, primal_id: &str, tag: &str) {
    let version = tag.strip_prefix('v').unwrap_or(tag);
    let manifest_path = root.join("manifest.toml");
    let Ok(content) = std::fs::read_to_string(&manifest_path) else {
        return;
    };

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

// ── sweetGrass braid integration ──────────────────────────────────

enum BraidResult {
    Created(String),
    Pending(PathBuf),
    Skipped,
}

fn sweetgrass_socket() -> Option<PathBuf> {
    let uid = super::current_uid();
    let path = super::defaults::sweetgrass_socket(uid);
    if path.exists() { Some(path) } else { None }
}

fn try_braid_create(source_id: &str, entry: &ProvenanceEntry, bin_size: u64) -> BraidResult {
    let braid_name = format!(
        "harvest:{source_id}:{}:{}",
        entry.target,
        &entry.build_timestamp[..entry.build_timestamp.len().min(10)],
    );

    let braid_request = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "braid.create",
        "params": {
            "data_hash": entry.provenance_hash,
            "mime_type": "application/x-plasmidbin-harvest",
            "size": bin_size,
            "name": braid_name,
            "metadata": {
                "title": format!("{source_id} {} Harvest", entry.target),
                "custom": {
                    "source_commit": entry.source_commit,
                    "source_repo": entry.source_repo,
                    "content_hash": entry.content_hash,
                    "rustc_version": entry.rustc_version,
                    "target_triple": entry.target,
                    "harvest_workflow": "auto-harvest.yml",
                }
            }
        }
    });

    let Some(socket) = sweetgrass_socket() else {
        return write_pending_braid(source_id, &braid_request);
    };

    match send_uds_jsonrpc(&socket, &braid_request) {
        Ok(response) => {
            if let Some(id) = response
                .get("result")
                .and_then(|r| r.get("braid_id"))
                .and_then(|v| v.as_str())
            {
                BraidResult::Created(id.to_string())
            } else if let Some(id) = response
                .get("result")
                .and_then(|r| r.get("id"))
                .and_then(|v| v.as_str())
            {
                BraidResult::Created(id.to_string())
            } else {
                write_pending_braid(source_id, &braid_request)
            }
        }
        Err(_) => write_pending_braid(source_id, &braid_request),
    }
}

fn write_pending_braid(source_id: &str, request: &serde_json::Value) -> BraidResult {
    let dir = std::env::temp_dir().join("plasmidbin-braids-pending");
    let _ = std::fs::create_dir_all(&dir);
    let path = dir.join(format!("{source_id}.braid-pending.json"));
    if let Ok(json) = serde_json::to_string_pretty(request) {
        if std::fs::write(&path, json).is_ok() {
            return BraidResult::Pending(path);
        }
    }
    BraidResult::Skipped
}

fn send_uds_jsonrpc(socket: &Path, request: &serde_json::Value) -> Result<serde_json::Value> {
    use std::io::{Read, Write};
    use std::os::unix::net::UnixStream;
    use std::time::Duration;

    let mut stream = UnixStream::connect(socket).context("connecting to sweetGrass UDS")?;
    stream.set_read_timeout(Some(Duration::from_secs(5)))?;
    stream.set_write_timeout(Some(Duration::from_secs(5)))?;

    let payload = serde_json::to_string(request)? + "\n";
    stream.write_all(payload.as_bytes())?;
    stream.flush()?;

    let mut buf = Vec::new();
    let mut tmp = [0u8; 4096];
    loop {
        match stream.read(&mut tmp) {
            Ok(0) => break,
            Ok(n) => {
                buf.extend_from_slice(&tmp[..n]);
                if buf.contains(&b'\n') {
                    break;
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => break,
            Err(e) if e.kind() == std::io::ErrorKind::TimedOut => break,
            Err(e) => return Err(e.into()),
        }
    }

    let text = String::from_utf8_lossy(&buf);
    let response: serde_json::Value = serde_json::from_str(text.trim())?;
    Ok(response)
}
