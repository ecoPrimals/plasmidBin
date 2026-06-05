// SPDX-License-Identifier: AGPL-3.0-or-later

//! `plasmidbin fetch` — download binaries from GitHub Releases with BLAKE3 verification.

use anyhow::{Result, bail};
use clap::Args;
use plasmidbin_types::arch::Arch;
use plasmidbin_types::checksums::ChecksumsFile;
use plasmidbin_types::sources::SourcesFile;
use std::path::{Path, PathBuf};

#[derive(Args)]
pub struct FetchArgs {
    /// Fetch all primals
    #[arg(long)]
    all: bool,

    /// Fetch a single primal by name
    #[arg(long)]
    primal: Option<String>,

    /// Download from specific GitHub Release tag
    #[arg(long)]
    release: Option<String>,

    /// Re-download even if binary already exists
    #[arg(long)]
    force: bool,

    /// Show what would be downloaded without fetching
    #[arg(long)]
    dry_run: bool,

    /// plasmidBin root directory
    #[arg(long, default_value = ".")]
    root: PathBuf,
}

pub fn run(args: FetchArgs) -> Result<()> {
    if !args.all && args.primal.is_none() {
        bail!("specify --all or --primal NAME");
    }

    let root = &args.root;
    let arch = Arch::detect()?;
    let triple = arch.triple();

    let sources = SourcesFile::load(root)?;
    let checksums = ChecksumsFile::load(root).unwrap_or_else(|_| ChecksumsFile {
        primals: Default::default(),
    });

    let tag = resolve_release_tag(&args.release)?;
    let recent_tags = resolve_recent_tags();

    let source = if super::defaults::has_sovereign_release_url() {
        "sovereign (PLASMIDBIN_RELEASE_URL)"
    } else {
        "GitHub Releases"
    };

    println!("plasmidBin fetch");
    println!("Arch:    {triple}");
    println!("Source:  {source}");
    println!(
        "Release: {} ({} recent releases indexed)",
        tag.as_deref().unwrap_or("<none>"),
        recent_tags.len()
    );
    println!();

    let primals_dir = root.join("primals").join(triple);
    std::fs::create_dir_all(&primals_dir)?;

    let mut downloaded = 0u32;
    let mut verified = 0u32;
    let mut skipped = 0u32;
    let mut failed = 0u32;

    for (id, entry) in &sources.sources {
        if !args.all {
            if let Some(ref filter) = args.primal {
                if id != filter {
                    continue;
                }
            }
        }

        let bin_name = entry.binary_name(id);
        let local_path = primals_dir.join(&bin_name);
        let asset_arch = arch.asset_name(&bin_name);

        print!("  [{id}] ");

        let has_checksums = checksums.get_hash(id, triple).is_some()
            || checksums.get_hash(&bin_name, triple).is_some();

        if args.all && !has_checksums {
            println!("SKIP  not yet shipped (no checksums entry)");
            skipped += 1;
            continue;
        }

        if local_path.exists() && !args.force {
            println!("EXISTS  {bin_name} (use --force to re-download)");
            skipped += 1;
            continue;
        }

        if args.force {
            let _ = std::fs::remove_file(&local_path);
        }

        let mut got_it = false;

        // Try latest tag first, then recent tags
        let mut tags_to_try: Vec<&str> = Vec::new();
        if let Some(ref t) = tag {
            tags_to_try.push(t);
        }
        for t in &recent_tags {
            if Some(t.as_str()) != tag.as_deref() {
                tags_to_try.push(t);
            }
        }

        let id_asset = arch.asset_name(id);

        for try_tag in &tags_to_try {
            if args.dry_run {
                println!("OK  [dry-run] would download {asset_arch} from {try_tag}");
                got_it = true;
                break;
            }
            if download_from_release(try_tag, &asset_arch, &local_path)
                || download_from_release(try_tag, &id_asset, &local_path)
                || download_from_release(try_tag, &bin_name, &local_path)
                || download_from_release(try_tag, id, &local_path)
            {
                got_it = true;
                break;
            }
        }

        if !got_it {
            println!("FAIL  could not download {bin_name}");
            failed += 1;
            continue;
        }

        if args.dry_run {
            downloaded += 1;
            continue;
        }

        if let Some(expected) = checksums.get_hash(&bin_name, triple) {
            let actual = blake3_file(&local_path)?;
            if actual == expected {
                println!("OK  checksum verified");
                verified += 1;
            } else {
                println!("FAIL  checksum mismatch (removing)");
                let _ = std::fs::remove_file(&local_path);
                failed += 1;
                continue;
            }
        } else {
            println!("OK  (no checksum entry to verify)");
        }

        downloaded += 1;
    }

    // Backward-compat symlinks
    if !args.dry_run {
        create_compat_symlinks(root, triple)?;
    }

    println!();
    println!("Summary:");
    println!("  Downloaded: {downloaded}");
    println!("  Verified:   {verified}");
    println!("  Skipped:    {skipped}");
    println!("  Failed:     {failed}");

    if failed > 0 {
        bail!("{failed} downloads failed");
    }
    Ok(())
}

fn gh_output_with_timeout(args: &[&str], timeout_secs: u64) -> Option<std::process::Output> {
    use std::time::{Duration, Instant};

    let mut child = match std::process::Command::new("gh")
        .args(args)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
    {
        Ok(c) => c,
        Err(_) => return None,
    };

    let deadline = Instant::now() + Duration::from_secs(timeout_secs);
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                let stdout = child
                    .stdout
                    .take()
                    .and_then(|mut s| {
                        use std::io::Read;
                        let mut buf = Vec::new();
                        s.read_to_end(&mut buf).ok().map(|_| buf)
                    })
                    .unwrap_or_default();
                let stderr = child
                    .stderr
                    .take()
                    .and_then(|mut s| {
                        use std::io::Read;
                        let mut buf = Vec::new();
                        s.read_to_end(&mut buf).ok().map(|_| buf)
                    })
                    .unwrap_or_default();
                return Some(std::process::Output {
                    status,
                    stdout,
                    stderr,
                });
            }
            Ok(None) => {
                if Instant::now() >= deadline {
                    let _ = child.kill();
                    let _ = child.wait();
                    return None;
                }
                std::thread::sleep(Duration::from_millis(100));
            }
            Err(_) => return None,
        }
    }
}

fn resolve_release_tag(explicit: &Option<String>) -> Result<Option<String>> {
    if let Some(tag) = explicit {
        return Ok(Some(tag.clone()));
    }
    let output = gh_output_with_timeout(
        &[
            "release",
            "view",
            "--repo",
            &super::defaults::org_repo(),
            "--json",
            "tagName",
            "-q",
            ".tagName",
        ],
        15,
    );
    match output {
        Some(o) if o.status.success() => {
            let tag = String::from_utf8_lossy(&o.stdout).trim().to_string();
            if tag.is_empty() {
                Ok(None)
            } else {
                Ok(Some(tag))
            }
        }
        _ => Ok(None),
    }
}

fn resolve_recent_tags() -> Vec<String> {
    let output = gh_output_with_timeout(
        &[
            "release",
            "list",
            "--repo",
            &super::defaults::org_repo(),
            "-L",
            "10",
        ],
        15,
    );
    match output {
        Some(o) if o.status.success() => String::from_utf8_lossy(&o.stdout)
            .lines()
            .filter_map(|line| line.split_whitespace().last().map(String::from))
            .collect(),
        _ => Vec::new(),
    }
}

fn download_from_release(tag: &str, asset_name: &str, dest: &Path) -> bool {
    let url = super::defaults::release_download_url(tag, asset_name);
    let status = std::process::Command::new("curl")
        .args(["-sfL", "--max-time", "300", "-o"])
        .arg(dest)
        .arg(&url)
        .status();
    match status {
        Ok(s) if s.success() => {
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let _ = std::fs::set_permissions(dest, std::fs::Permissions::from_mode(0o755));
            }
            true
        }
        _ => false,
    }
}

use super::defaults::blake3_file;

fn create_compat_symlinks(root: &Path, triple: &str) -> Result<()> {
    let arch_dir = root.join("primals").join(triple);
    if !arch_dir.exists() {
        return Ok(());
    }

    let mut count = 0;
    for entry in std::fs::read_dir(&arch_dir)? {
        let entry = entry?;
        if !entry.file_type()?.is_file() {
            continue;
        }
        let name = entry.file_name();
        let link = root.join("primals").join(&name);
        if link.exists() && !link.is_symlink() {
            continue;
        }

        #[cfg(unix)]
        {
            let _ = std::fs::remove_file(&link);
            let target = format!("{triple}/{}", name.to_string_lossy());
            std::os::unix::fs::symlink(&target, &link)?;
            count += 1;
        }
    }
    if count > 0 {
        println!("Symlinked: {count} (primals/{{name}} -> {triple}/{{name}})");
    }
    Ok(())
}
