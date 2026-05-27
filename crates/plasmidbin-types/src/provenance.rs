// SPDX-License-Identifier: AGPL-3.0-or-later

//! Typed parsing and generation for `provenance.toml`.
//!
//! Each harvest records a composite provenance fingerprint that includes the
//! content hash, source commit, build timestamp, compiler version, and target
//! triple.  The `provenance_hash` changes whenever ANY of these inputs change,
//! even if the stripped binary bytes are bitwise identical.

use crate::{Report, is_valid_blake3_hex};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::Path;

/// Domain prefix mixed into provenance hashes so they never collide with
/// raw content hashes or seed fingerprints.
const PROVENANCE_DOMAIN: &str = "plasmidbin-provenance-v1";

/// Per-arch provenance record for a single harvested binary.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct ProvenanceEntry {
    pub content_hash: String,
    pub source_commit: String,
    pub source_repo: String,
    pub build_timestamp: String,
    pub rustc_version: String,
    pub target: String,
    pub provenance_hash: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub braid_id: Option<String>,
}

/// Top-level structure of `provenance.toml`.
/// Keyed by primal name → target triple → provenance entry.
#[derive(Debug, Default, Deserialize, Serialize)]
pub struct ProvenanceFile {
    #[serde(default)]
    pub primals: BTreeMap<String, BTreeMap<String, ProvenanceEntry>>,
}

impl ProvenanceFile {
    pub fn load(root: &Path) -> Result<Self, String> {
        let path = root.join("provenance.toml");
        if !path.exists() {
            return Ok(Self::default());
        }
        let content = std::fs::read_to_string(&path)
            .map_err(|e| format!("cannot read {}: {e}", path.display()))?;
        toml::from_str(&content)
            .map_err(|e| format!("provenance.toml schema error: {e}"))
    }

    pub fn save(&self, root: &Path) -> Result<(), String> {
        let path = root.join("provenance.toml");
        let mut output = String::from(
            "# plasmidBin provenance — composite fingerprints\n\
             #\n\
             # Each entry records the content hash, source commit, build timestamp,\n\
             # compiler version, and a composite provenance_hash that changes whenever\n\
             # any input changes — even if the binary bytes are bitwise identical.\n\
             #\n\
             # Validated by: plasmidbin verify-provenance\n\n",
        );
        for (name, arches) in &self.primals {
            for (triple, entry) in arches {
                output.push_str(&format!("[primals.{name}.\"{triple}\"]\n"));
                output.push_str(&format!("content_hash = \"{}\"\n", entry.content_hash));
                output.push_str(&format!("source_commit = \"{}\"\n", entry.source_commit));
                output.push_str(&format!("source_repo = \"{}\"\n", entry.source_repo));
                output.push_str(&format!("build_timestamp = \"{}\"\n", entry.build_timestamp));
                output.push_str(&format!("rustc_version = \"{}\"\n", entry.rustc_version));
                output.push_str(&format!("target = \"{}\"\n", entry.target));
                output.push_str(&format!("provenance_hash = \"{}\"\n", entry.provenance_hash));
                if let Some(ref braid) = entry.braid_id {
                    output.push_str(&format!("braid_id = \"{braid}\"\n"));
                }
                output.push('\n');
            }
        }
        std::fs::write(&path, output)
            .map_err(|e| format!("cannot write {}: {e}", path.display()))
    }

    pub fn set_entry(&mut self, primal: &str, triple: &str, entry: ProvenanceEntry) {
        self.primals
            .entry(primal.to_owned())
            .or_default()
            .insert(triple.to_owned(), entry);
    }

    pub fn get_entry(&self, primal: &str, triple: &str) -> Option<&ProvenanceEntry> {
        self.primals.get(primal)?.get(triple)
    }
}

/// Compute the composite provenance hash from its constituent fields.
pub fn compute_provenance_hash(
    content_hash: &str,
    source_commit: &str,
    build_timestamp: &str,
    rustc_version: &str,
    target: &str,
) -> String {
    let input = format!(
        "{PROVENANCE_DOMAIN}{content_hash}{source_commit}{build_timestamp}{rustc_version}{target}"
    );
    blake3::hash(input.as_bytes()).to_hex().to_string()
}

/// Build sidecar written by `plasmidbin build` next to the staged binary.
/// Read by `plasmidbin harvest` to populate provenance entries.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct BuildSidecar {
    pub source_commit: String,
    pub source_repo: String,
    pub rustc_version: String,
    pub build_timestamp: String,
}

impl BuildSidecar {
    pub fn sidecar_path(binary_path: &Path) -> std::path::PathBuf {
        let mut p = binary_path.as_os_str().to_owned();
        p.push(".provenance.json");
        std::path::PathBuf::from(p)
    }

    pub fn write_next_to(binary_path: &Path, sidecar: &Self) -> Result<(), String> {
        let path = Self::sidecar_path(binary_path);
        let json = serde_json::to_string_pretty(sidecar)
            .map_err(|e| format!("serialize sidecar: {e}"))?;
        std::fs::write(&path, json)
            .map_err(|e| format!("cannot write {}: {e}", path.display()))
    }

    pub fn read_next_to(binary_path: &Path) -> Option<Self> {
        let path = Self::sidecar_path(binary_path);
        let content = std::fs::read_to_string(&path).ok()?;
        serde_json::from_str(&content).ok()
    }
}

pub fn validate(root: &Path) -> Report {
    let path = root.join("provenance.toml");
    let mut report = Report::default();

    if !path.exists() {
        report.pass("provenance.toml not present (optional)");
        return report;
    }

    let content = match std::fs::read_to_string(&path) {
        Ok(c) => c,
        Err(e) => {
            report.fail(&format!("cannot read {}: {e}", path.display()));
            return report;
        }
    };

    let prov: ProvenanceFile = match toml::from_str(&content) {
        Ok(p) => {
            report.pass("provenance.toml parses as valid TOML with typed schema");
            p
        }
        Err(e) => {
            report.fail(&format!("provenance.toml schema error: {e}"));
            return report;
        }
    };

    let mut entries = 0u32;
    for (id, arches) in &prov.primals {
        for (triple, entry) in arches {
            entries += 1;

            if !is_valid_blake3_hex(&entry.content_hash) {
                report.fail(&format!("primals.{id}.{triple}: invalid content_hash"));
                continue;
            }
            if !is_valid_blake3_hex(&entry.provenance_hash) {
                report.fail(&format!("primals.{id}.{triple}: invalid provenance_hash"));
                continue;
            }

            let recomputed = compute_provenance_hash(
                &entry.content_hash,
                &entry.source_commit,
                &entry.build_timestamp,
                &entry.rustc_version,
                &entry.target,
            );
            if recomputed != entry.provenance_hash {
                report.fail(&format!(
                    "primals.{id}.{triple}: provenance_hash mismatch \
                     (stored={}, recomputed={})",
                    &entry.provenance_hash[..16],
                    &recomputed[..16],
                ));
            } else {
                report.pass(&format!("primals.{id}.{triple}: provenance_hash valid"));
            }
        }
    }

    report.pass(&format!("{entries} provenance entries validated"));
    report
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn provenance_hash_changes_with_timestamp() {
        let h1 = compute_provenance_hash("aaa", "bbb", "2026-05-27T10:00:00Z", "1.87.0", "x86_64");
        let h2 = compute_provenance_hash("aaa", "bbb", "2026-05-27T11:00:00Z", "1.87.0", "x86_64");
        assert_ne!(h1, h2);
    }

    #[test]
    fn provenance_hash_changes_with_commit() {
        let h1 = compute_provenance_hash("aaa", "commit_a", "2026-05-27T10:00:00Z", "1.87.0", "x86_64");
        let h2 = compute_provenance_hash("aaa", "commit_b", "2026-05-27T10:00:00Z", "1.87.0", "x86_64");
        assert_ne!(h1, h2);
    }

    #[test]
    fn provenance_hash_deterministic() {
        let h1 = compute_provenance_hash("aaa", "bbb", "ts", "rc", "tgt");
        let h2 = compute_provenance_hash("aaa", "bbb", "ts", "rc", "tgt");
        assert_eq!(h1, h2);
    }

    #[test]
    fn round_trip_toml() {
        let mut prov = ProvenanceFile::default();
        prov.set_entry("beardog", "x86_64-unknown-linux-musl", ProvenanceEntry {
            content_hash: "a".repeat(64),
            source_commit: "abc123".into(),
            source_repo: "ecoPrimals/bearDog".into(),
            build_timestamp: "2026-05-27T10:00:00Z".into(),
            rustc_version: "1.87.0".into(),
            target: "x86_64-unknown-linux-musl".into(),
            provenance_hash: "b".repeat(64),
            braid_id: None,
        });
        let dir = std::env::temp_dir().join("plasmidbin-prov-test");
        let _ = std::fs::create_dir_all(&dir);
        prov.save(&dir).unwrap();
        let loaded = ProvenanceFile::load(&dir).unwrap();
        let entry = loaded.get_entry("beardog", "x86_64-unknown-linux-musl").unwrap();
        assert_eq!(entry.source_commit, "abc123");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
