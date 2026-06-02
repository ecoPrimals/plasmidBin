// SPDX-License-Identifier: AGPL-3.0-or-later

//! Centralized defaults and path conventions for plasmidBin.
//!
//! All hardcoded paths, org/repo references, and build staging directories
//! are consolidated here with env-var overrides. Follows the same pattern as
//! primalSpring's `tolerances/mod.rs`.
//!
//! Some functions are pre-wired for upcoming integration (stop, doctor, deploy
//! evolution) and not yet called.

#![allow(dead_code)]

use std::path::PathBuf;

/// Default remote directory for primal binaries on gates/VPS.
/// Override: `ECOPRIMALS_PLASMID_BIN`
pub const DEFAULT_REMOTE_DIR: &str = "/opt/plasmidBin";

/// GitHub organization name. Override: `ECOPRIMALS_ORG`
pub const DEFAULT_ORG: &str = "ecoPrimals";

/// GitHub repository for plasmidBin releases. Override: `ECOPRIMALS_PLASMID_REPO`
pub const DEFAULT_PLASMID_REPO: &str = "plasmidBin";

/// Android ADB deployment directory (GrapheneOS/Pixel).
pub const ANDROID_DEPLOY_DIR: &str = "/data/local/tmp/plasmidBin/primals";

/// Resolved GitHub org/repo slug (e.g. `"ecoPrimals/plasmidBin"`).
pub fn org_repo() -> String {
    let org = std::env::var("ECOPRIMALS_ORG").unwrap_or_else(|_| DEFAULT_ORG.to_owned());
    let repo =
        std::env::var("ECOPRIMALS_PLASMID_REPO").unwrap_or_else(|_| DEFAULT_PLASMID_REPO.to_owned());
    format!("{org}/{repo}")
}

/// Resolved remote plasmidBin directory (env override or compile-time default).
pub fn remote_dir() -> String {
    std::env::var("ECOPRIMALS_PLASMID_BIN").unwrap_or_else(|_| DEFAULT_REMOTE_DIR.to_owned())
}

/// Build staging directory. Override: `ECOPRIMALS_BUILD_DIR`
pub fn build_dir() -> PathBuf {
    std::env::var("ECOPRIMALS_BUILD_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            std::env::var("TMPDIR")
                .map(PathBuf::from)
                .unwrap_or_else(|_| PathBuf::from("/tmp"))
                .join("primalspring-build")
        })
}

/// Deploy staging directory for a given target triple.
/// Override: `ECOPRIMALS_DEPLOY_DIR`
pub fn deploy_dir(triple: &str) -> PathBuf {
    std::env::var("ECOPRIMALS_DEPLOY_DIR")
        .map(|d| PathBuf::from(d).join(triple))
        .unwrap_or_else(|_| {
            std::env::var("TMPDIR")
                .map(PathBuf::from)
                .unwrap_or_else(|_| PathBuf::from("/tmp"))
                .join("primalspring-deploy/primals")
                .join(triple)
        })
}

/// Log file path for a primal process.
///
/// Uses `$XDG_RUNTIME_DIR/biomeos/logs/` when available, falls back to `/tmp/`.
pub fn log_path(name: &str) -> PathBuf {
    if let Ok(runtime) = std::env::var("XDG_RUNTIME_DIR") {
        let log_dir = PathBuf::from(runtime).join("biomeos/logs");
        let _ = std::fs::create_dir_all(&log_dir);
        return log_dir.join(format!("{name}.log"));
    }
    PathBuf::from(format!("/tmp/{name}.log"))
}

/// GitHub release download URL for a given tag and asset name.
pub fn release_download_url(tag: &str, asset_name: &str) -> String {
    let org = std::env::var("ECOPRIMALS_ORG").unwrap_or_else(|_| DEFAULT_ORG.to_owned());
    let repo =
        std::env::var("ECOPRIMALS_PLASMID_REPO").unwrap_or_else(|_| DEFAULT_PLASMID_REPO.to_owned());
    format!("https://github.com/{org}/{repo}/releases/download/{tag}/{asset_name}")
}

/// Git clone URL for plasmidBin.
pub fn clone_url() -> String {
    let org = std::env::var("ECOPRIMALS_ORG").unwrap_or_else(|_| DEFAULT_ORG.to_owned());
    let repo =
        std::env::var("ECOPRIMALS_PLASMID_REPO").unwrap_or_else(|_| DEFAULT_PLASMID_REPO.to_owned());
    format!("https://github.com/{org}/{repo}.git")
}

/// Runtime directory paths for socket/PID scanning.
///
/// Returns biomeos and ecoprimals runtime directories for the given UID.
pub fn runtime_socket_dirs(uid: u32) -> Vec<PathBuf> {
    vec![
        PathBuf::from(format!("/run/user/{uid}/biomeos")),
        PathBuf::from(format!("/run/user/{uid}/ecoprimals")),
    ]
}

/// SweetGrass socket path for provenance braid operations.
pub fn sweetgrass_socket(uid: u32) -> PathBuf {
    std::env::var("SWEETGRASS_SOCKET")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from(format!("/run/user/{uid}/ecoprimals/sweetgrass.sock")))
}

/// UTC ISO-8601 timestamp with second precision (no chrono dependency).
///
/// Format: `2026-06-01T21:52:00Z`
pub fn utc_now_rfc3339() -> String {
    let dur = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    let secs = dur.as_secs();

    let days = secs / 86400;
    let day_secs = secs % 86400;
    let hour = day_secs / 3600;
    let min = (day_secs % 3600) / 60;
    let sec = day_secs % 60;

    let (year, month, day) = days_to_date(days);
    format!("{year:04}-{month:02}-{day:02}T{hour:02}:{min:02}:{sec:02}Z")
}

fn days_to_date(days_since_epoch: u64) -> (u32, u32, u32) {
    // Algorithm from Howard Hinnant's chrono-compatible date library.
    let z = days_since_epoch as i64 + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u32;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    #[expect(clippy::cast_sign_loss, reason = "year is positive for all valid dates post-epoch")]
    (y as u32, m, d)
}
