// SPDX-License-Identifier: AGPL-3.0-or-later

//! Typed parsing and validation for `checksums.toml`.

use crate::{Report, is_valid_blake3_hex};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

/// Top-level structure of `checksums.toml`.
/// Each key under `[primals]` is a primal name mapping to arch→hash.
#[derive(Debug, Deserialize, Serialize)]
pub struct ChecksumsFile {
    #[serde(default)]
    pub primals: BTreeMap<String, BTreeMap<String, String>>,
}

impl ChecksumsFile {
    pub fn load(root: &Path) -> Result<Self, String> {
        let path = root.join("checksums.toml");
        let content = std::fs::read_to_string(&path)
            .map_err(|e| format!("cannot read {}: {e}", path.display()))?;
        toml::from_str(&content)
            .map_err(|e| format!("checksums.toml schema error: {e}"))
    }

    /// Write back to disk, preserving TOML formatting via serde round-trip.
    pub fn save(&self, root: &Path) -> Result<(), String> {
        let path = root.join("checksums.toml");
        let mut output = String::from(
            "# plasmidBin checksums — blake3\n\
             #\n\
             # One entry per binary, keyed by full target triple.\n\
             # Validated by plasmidbin validate.\n\
             #\n\
             # genomeBin layout: primals/{target-triple}/{primal}\n\n",
        );
        for (name, hashes) in &self.primals {
            output.push_str(&format!("[primals.{name}]\n"));
            for (triple, hash) in hashes {
                output.push_str(&format!("\"{triple}\" = \"{hash}\"\n"));
            }
            output.push('\n');
        }
        std::fs::write(&path, output)
            .map_err(|e| format!("cannot write {}: {e}", path.display()))
    }

    pub fn get_hash(&self, primal: &str, triple: &str) -> Option<&str> {
        self.primals.get(primal)?.get(triple).map(String::as_str)
    }

    pub fn set_hash(&mut self, primal: &str, triple: &str, hash: &str) {
        self.primals
            .entry(primal.to_owned())
            .or_default()
            .insert(triple.to_owned(), hash.to_owned());
    }
}

pub struct ChecksumReport {
    pub report: Report,
    pub primal_ids: BTreeSet<String>,
}

pub fn validate(root: &Path, _manifest_primals: &BTreeSet<String>) -> ChecksumReport {
    let path = root.join("checksums.toml");
    let mut report = Report::default();
    let mut primal_ids = BTreeSet::new();

    let content = match std::fs::read_to_string(&path) {
        Ok(c) => c,
        Err(e) => {
            report.fail(&format!("cannot read {}: {e}", path.display()));
            return ChecksumReport { report, primal_ids };
        }
    };

    let checksums: ChecksumsFile = match toml::from_str(&content) {
        Ok(c) => {
            report.pass("checksums.toml parses as valid TOML with typed schema");
            c
        }
        Err(e) => {
            report.fail(&format!("checksums.toml schema error: {e}"));
            return ChecksumReport { report, primal_ids };
        }
    };

    for (id, hashes) in &checksums.primals {
        primal_ids.insert(id.clone());
        let mut id_ok = true;

        if hashes.is_empty() {
            report.fail(&format!("primals.{id}: no checksums for any target triple"));
            continue;
        }

        for (triple, hash) in hashes {
            if !is_valid_blake3_hex(hash) {
                report.fail(&format!("primals.{id}.{triple}: invalid BLAKE3 hash '{hash}'"));
                id_ok = false;
            }
        }

        if id_ok {
            report.pass(&format!(
                "primals.{id}: {} target triples, all valid BLAKE3",
                hashes.len()
            ));
        }
    }

    report.pass(&format!("{} primals with checksums", primal_ids.len()));

    ChecksumReport { report, primal_ids }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_typed_checksums() {
        let toml_str = r#"
[primals.beardog]
"x86_64-unknown-linux-musl" = "6ca141176cab1d864bc507b9e257826125db8c5497245176e28d9e6dee7fa2c3"
"aarch64-unknown-linux-musl" = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
"#;
        let c: ChecksumsFile = toml::from_str(toml_str).unwrap();
        assert_eq!(c.primals.len(), 1);
        assert_eq!(c.primals["beardog"].len(), 2);
    }

    #[test]
    fn set_and_get_hash() {
        let mut c = ChecksumsFile { primals: BTreeMap::new() };
        let hash = "6ca141176cab1d864bc507b9e257826125db8c5497245176e28d9e6dee7fa2c3";
        c.set_hash("beardog", "x86_64-unknown-linux-musl", hash);
        assert_eq!(c.get_hash("beardog", "x86_64-unknown-linux-musl"), Some(hash));
    }
}
