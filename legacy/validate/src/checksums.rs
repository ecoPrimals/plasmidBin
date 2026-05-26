// SPDX-License-Identifier: AGPL-3.0-or-later

//! Typed validation for `checksums.toml` — BLAKE3 hashes per binary per arch.

use crate::types::{Report, is_valid_blake3_hex};
use serde::Deserialize;
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

#[derive(Debug, Deserialize)]
struct ChecksumsFile {
    #[serde(default)]
    primals: BTreeMap<String, BTreeMap<String, String>>,
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
            report.pass(&format!("primals.{id}: {} target triples, all valid BLAKE3", hashes.len()));
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
    fn detects_bad_hash() {
        let toml_str = r#"
[primals.bad]
"x86_64-unknown-linux-musl" = "not-a-hash"
"#;
        let c: ChecksumsFile = toml::from_str(toml_str).unwrap();
        assert!(!is_valid_blake3_hex(&c.primals["bad"]["x86_64-unknown-linux-musl"]));
    }
}
