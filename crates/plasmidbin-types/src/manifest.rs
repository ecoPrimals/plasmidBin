// SPDX-License-Identifier: AGPL-3.0-or-later

//! Typed parsing and validation for `manifest.toml`.

use crate::{MIN_PRIMALS, Report, is_valid_blake3_hex};
use serde::Deserialize;
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

#[derive(Debug, Deserialize)]
pub struct ManifestFile {
    pub manifest: ManifestMeta,
    #[serde(default)]
    pub primals: BTreeMap<String, PrimalEntry>,
    #[serde(default)]
    pub atomics: BTreeMap<String, AtomicDef>,
    #[serde(default)]
    pub springs: BTreeMap<String, SpringEntry>,
    #[serde(default)]
    pub niches: BTreeMap<String, NicheEntry>,
    #[serde(default)]
    pub binaries: BTreeMap<String, toml::Value>,
    #[serde(default)]
    pub membrane: BTreeMap<String, toml::Value>,
    #[serde(default)]
    pub sporegarden: BTreeMap<String, toml::Value>,
}

#[derive(Debug, Deserialize)]
pub struct ManifestMeta {
    pub version: String,
    pub format: String,
    pub generated: String,
    pub checksum_algorithm: String,
    pub mirror_url: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct PrimalEntry {
    pub name: String,
    pub description: String,
    pub latest: String,
    pub phase: u8,
    #[serde(default)]
    pub capabilities: Vec<String>,
    pub seed_fingerprint: Option<String>,
    pub ecobin_grade: Option<String>,
    #[serde(default)]
    pub stripped: Option<bool>,
    #[serde(default)]
    pub arch: Vec<String>,
    #[serde(default)]
    pub check_pass: Vec<String>,
    #[serde(default)]
    pub is_orchestrator: Option<bool>,
    #[serde(default)]
    pub modes: Vec<String>,
    #[serde(default)]
    pub build_from_source: Option<bool>,
    pub binary: Option<String>,
    pub build_package: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct AtomicDef {
    pub name: Option<String>,
    pub particle: Option<String>,
    pub description: Option<String>,
    #[serde(default)]
    pub primals: Vec<String>,
    pub graph: Option<String>,
    #[serde(default)]
    pub niches: BTreeMap<String, toml::Value>,
}

#[derive(Debug, Deserialize)]
pub struct SpringEntry {
    pub name: Option<String>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, toml::Value>,
}

#[derive(Debug, Deserialize)]
pub struct NicheEntry {
    pub name: Option<String>,
    #[serde(default)]
    pub primals: Vec<String>,
    pub description: Option<String>,
    pub composition: Option<String>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, toml::Value>,
}

pub struct ManifestReport {
    pub report: Report,
    pub primal_ids: BTreeSet<String>,
    pub spring_ids: BTreeSet<String>,
}

impl ManifestFile {
    pub fn load(root: &Path) -> crate::error::Result<Self> {
        let path = root.join("manifest.toml");
        let content =
            std::fs::read_to_string(&path).map_err(|e| crate::error::TypesError::ReadFile {
                path: path.clone(),
                source: e,
            })?;
        toml::from_str(&content).map_err(|e| crate::error::TypesError::TomlParse {
            file: "manifest.toml",
            source: e,
        })
    }
}

pub fn validate(root: &Path) -> ManifestReport {
    let path = root.join("manifest.toml");
    let mut report = Report::default();
    let mut primal_ids = BTreeSet::new();
    let mut spring_ids = BTreeSet::new();

    let content = match std::fs::read_to_string(&path) {
        Ok(c) => c,
        Err(e) => {
            report.fail(&format!("cannot read {}: {e}", path.display()));
            return ManifestReport {
                report,
                primal_ids,
                spring_ids,
            };
        }
    };

    let manifest: ManifestFile = match toml::from_str(&content) {
        Ok(m) => {
            report.pass("manifest.toml parses as valid TOML with typed schema");
            m
        }
        Err(e) => {
            report.fail(&format!("manifest.toml schema error: {e}"));
            return ManifestReport {
                report,
                primal_ids,
                spring_ids,
            };
        }
    };

    report.pass(&format!(
        "[manifest] version={}, format={}",
        manifest.manifest.version, manifest.manifest.format
    ));

    for (id, entry) in &manifest.primals {
        primal_ids.insert(id.clone());

        if entry.capabilities.is_empty() {
            report.fail(&format!("primals.{id}: no capabilities declared"));
        } else {
            report.pass(&format!(
                "primals.{id}: {} v{}, {} capabilities",
                entry.name,
                entry.latest,
                entry.capabilities.len()
            ));
        }

        if let Some(ref fp) = entry.seed_fingerprint {
            if !is_valid_blake3_hex(fp) {
                report.fail(&format!("primals.{id}: invalid seed_fingerprint format"));
            }
        }
    }

    if primal_ids.len() >= MIN_PRIMALS {
        report.pass(&format!(
            "{} primal entries (>= {MIN_PRIMALS})",
            primal_ids.len()
        ));
    } else {
        report.fail(&format!(
            "only {} primal entries (expected >= {MIN_PRIMALS})",
            primal_ids.len()
        ));
    }

    for (name, atomic) in &manifest.atomics {
        let mut atomic_ok = true;
        for p in &atomic.primals {
            if !primal_ids.contains(p) {
                report.fail(&format!("atomics.{name}: references unknown primal '{p}'"));
                atomic_ok = false;
            }
        }
        if atomic_ok {
            report.pass(&format!(
                "atomics.{name}: {} primals, all valid",
                atomic.primals.len()
            ));
        }
    }

    for id in manifest.springs.keys() {
        spring_ids.insert(id.clone());
    }
    if !spring_ids.is_empty() {
        report.pass(&format!("{} spring entries", spring_ids.len()));
    }

    ManifestReport {
        report,
        primal_ids,
        spring_ids,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MINIMAL_MANIFEST: &str = r#"
[manifest]
version = "1.0.0"
format = "genomeBin"
generated = "2026-01-01T00:00:00Z"
checksum_algorithm = "blake3"

[primals.testprimal]
name = "TestPrimal"
description = "A test primal"
latest = "0.1.0"
phase = 1
capabilities = ["test"]
"#;

    #[test]
    fn parses_minimal_manifest() {
        let m: ManifestFile = toml::from_str(MINIMAL_MANIFEST).unwrap();
        assert_eq!(m.primals.len(), 1);
        assert_eq!(m.primals["testprimal"].name, "TestPrimal");
    }

    #[test]
    fn rejects_missing_manifest_section() {
        let bad = r#"
[primals.x]
name = "X"
description = "x"
latest = "0.1.0"
phase = 1
"#;
        let result: Result<ManifestFile, _> = toml::from_str(bad);
        assert!(result.is_err());
    }
}
