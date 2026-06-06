// SPDX-License-Identifier: AGPL-3.0-or-later

//! Typed parsing and validation for `sources.toml`.

use crate::Report;
use serde::Deserialize;
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

#[derive(Debug, Deserialize)]
pub struct SourcesFile {
    #[serde(default)]
    pub sources: BTreeMap<String, SourceEntry>,
}

#[derive(Debug, Deserialize)]
pub struct SourceEntry {
    pub repo: String,
    pub tag_pattern: String,
    #[serde(default)]
    pub assets: Vec<String>,
    #[serde(default)]
    pub private: bool,
    pub note: Option<String>,
    pub binary_name: Option<String>,
    pub build_args: Option<String>,
}

impl SourcesFile {
    pub fn load(root: &Path) -> crate::error::Result<Self> {
        let path = root.join("sources.toml");
        let content =
            std::fs::read_to_string(&path).map_err(|e| crate::error::TypesError::ReadFile {
                path: path.clone(),
                source: e,
            })?;
        toml::from_str(&content).map_err(|e| crate::error::TypesError::TomlParse {
            file: "sources.toml",
            source: e,
        })
    }
}

impl SourceEntry {
    pub fn binary_name(&self, id: &str) -> String {
        self.binary_name.clone().unwrap_or_else(|| id.to_owned())
    }
}

pub struct SourcesReport {
    pub report: Report,
    pub source_ids: BTreeSet<String>,
}

pub fn validate(root: &Path, _manifest_primals: &BTreeSet<String>) -> SourcesReport {
    let path = root.join("sources.toml");
    let mut report = Report::default();
    let mut source_ids = BTreeSet::new();

    let content = match std::fs::read_to_string(&path) {
        Ok(c) => c,
        Err(e) => {
            report.fail(&format!("cannot read {}: {e}", path.display()));
            return SourcesReport { report, source_ids };
        }
    };

    let sources: SourcesFile = match toml::from_str(&content) {
        Ok(s) => {
            report.pass("sources.toml parses as valid TOML with typed schema");
            s
        }
        Err(e) => {
            report.fail(&format!("sources.toml schema error: {e}"));
            return SourcesReport { report, source_ids };
        }
    };

    for (id, entry) in &sources.sources {
        source_ids.insert(id.clone());

        if !entry.repo.contains('/') {
            report.fail(&format!(
                "sources.{id}: repo '{}' not in org/repo format",
                entry.repo
            ));
            continue;
        }

        if !entry.tag_pattern.contains("{version}") {
            report.fail(&format!(
                "sources.{id}: tag_pattern '{}' missing {{version}} placeholder",
                entry.tag_pattern
            ));
            continue;
        }

        let detail = if entry.private { " (private)" } else { "" };
        report.pass(&format!("sources.{id}: {}{detail}", entry.repo));
    }

    report.pass(&format!("{} source entries", source_ids.len()));

    SourcesReport { report, source_ids }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_typed_sources() {
        let toml_str = r#"
[sources.beardog]
repo = "ecoPrimals/bearDog"
private = true
tag_pattern = "v{version}"
assets = ["beardog"]
note = "Crypto primitive"

[sources.songbird]
repo = "ecoPrimals/songBird"
tag_pattern = "v{version}"
assets = ["songbird"]
"#;
        let s: SourcesFile = toml::from_str(toml_str).unwrap();
        assert_eq!(s.sources.len(), 2);
        assert!(s.sources["beardog"].private);
    }

    #[test]
    fn binary_name_override() {
        let toml_str = r#"
[sources.biomeos]
repo = "ecoPrimals/biomeOS"
tag_pattern = "v{version}"
binary_name = "biomeos-unibin"
"#;
        let s: SourcesFile = toml::from_str(toml_str).unwrap();
        assert_eq!(
            s.sources["biomeos"].binary_name("biomeos"),
            "biomeos-unibin"
        );
    }
}
