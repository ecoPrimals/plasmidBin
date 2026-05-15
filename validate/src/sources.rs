// SPDX-License-Identifier: AGPL-3.0-or-later

use std::collections::BTreeSet;
use std::path::Path;

pub struct SourcesReport {
    pub passed: usize,
    pub failed: usize,
    pub source_ids: BTreeSet<String>,
}

pub fn validate(root: &Path, manifest_primals: &BTreeSet<String>) -> SourcesReport {
    let path = root.join("sources.toml");
    let mut passed = 0usize;
    let mut failed = 0usize;
    let mut source_ids = BTreeSet::new();

    let content = match std::fs::read_to_string(&path) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("FAIL: cannot read {}: {e}", path.display());
            return SourcesReport { passed: 0, failed: 1, source_ids };
        }
    };

    let parsed: toml::Value = match toml::from_str(&content) {
        Ok(v) => {
            passed += 1;
            println!("  PASS: sources.toml parses as valid TOML");
            v
        }
        Err(e) => {
            eprintln!("  FAIL: sources.toml parse error: {e}");
            return SourcesReport { passed, failed: failed + 1, source_ids };
        }
    };

    if let Some(sources) = parsed.get("sources").and_then(|s| s.as_table()) {
        for (id, entry) in sources {
            source_ids.insert(id.clone());

            let has_repo = entry.get("repo").and_then(|v| v.as_str()).is_some();
            let has_tag = entry.get("tag_pattern").and_then(|v| v.as_str()).is_some();

            if has_repo && has_tag {
                passed += 1;
            } else {
                failed += 1;
                let missing: Vec<&str> = [
                    (!has_repo).then_some("repo"),
                    (!has_tag).then_some("tag_pattern"),
                ].into_iter().flatten().collect();
                eprintln!("  FAIL: sources.{id} missing: {}", missing.join(", "));
            }
        }
        println!("  PASS: {} source entries", source_ids.len());
    } else {
        failed += 1;
        eprintln!("  FAIL: no [sources.*] sections found");
    }

    // Cross-check: manifest primals should have sources
    for mp in manifest_primals {
        if !source_ids.contains(mp) {
            eprintln!("  WARN: manifest primal '{mp}' has no source entry");
        }
    }

    SourcesReport { passed, failed, source_ids }
}
