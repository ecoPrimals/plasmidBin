// SPDX-License-Identifier: AGPL-3.0-or-later

//! Typed validation for `sources.toml` — GitHub source registry.

use crate::types::Report;
use serde::Deserialize;
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

#[derive(Debug, Deserialize)]
struct SourcesFile {
    #[serde(default)]
    sources: BTreeMap<String, SourceEntry>,
}

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
struct SourceEntry {
    repo: String,
    tag_pattern: String,
    #[serde(default)]
    assets: Vec<String>,
    #[serde(default)]
    private: bool,
    note: Option<String>,
    binary_name: Option<String>,
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
            report.fail(&format!("sources.{id}: repo '{}' not in org/repo format", entry.repo));
            continue;
        }

        if !entry.tag_pattern.contains("{version}") {
            report.fail(&format!("sources.{id}: tag_pattern '{}' missing {{version}} placeholder", entry.tag_pattern));
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
        assert!(!s.sources["songbird"].private);
    }

    #[test]
    fn detects_bad_repo_format() {
        let toml_str = r#"
[sources.bad]
repo = "noslash"
tag_pattern = "v{version}"
"#;
        let s: SourcesFile = toml::from_str(toml_str).unwrap();
        assert!(!s.sources["bad"].repo.contains('/'));
    }

    #[test]
    fn detects_missing_version_placeholder() {
        let toml_str = r#"
[sources.bad]
repo = "org/repo"
tag_pattern = "latest"
"#;
        let s: SourcesFile = toml::from_str(toml_str).unwrap();
        assert!(!s.sources["bad"].tag_pattern.contains("{version}"));
    }
}
