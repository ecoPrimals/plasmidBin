// SPDX-License-Identifier: AGPL-3.0-or-later

use std::collections::BTreeSet;
use std::path::Path;

pub struct ManifestReport {
    pub passed: usize,
    pub failed: usize,
    pub primal_ids: BTreeSet<String>,
    pub spring_ids: BTreeSet<String>,
}

pub fn validate(root: &Path) -> ManifestReport {
    let path = root.join("manifest.toml");
    let mut passed = 0usize;
    let mut failed = 0usize;
    let mut primal_ids = BTreeSet::new();
    let mut spring_ids = BTreeSet::new();

    let content = match std::fs::read_to_string(&path) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("FAIL: cannot read {}: {e}", path.display());
            return ManifestReport { passed: 0, failed: 1, primal_ids, spring_ids };
        }
    };

    let parsed: toml::Value = match toml::from_str(&content) {
        Ok(v) => {
            passed += 1;
            println!("  PASS: manifest.toml parses as valid TOML");
            v
        }
        Err(e) => {
            eprintln!("  FAIL: manifest.toml parse error: {e}");
            return ManifestReport { passed, failed: failed + 1, primal_ids, spring_ids };
        }
    };

    // [manifest] section
    if parsed.get("manifest").is_some() {
        passed += 1;
        println!("  PASS: [manifest] section present");
    } else {
        failed += 1;
        eprintln!("  FAIL: [manifest] section missing");
    }

    // [primals.*] sections
    if let Some(primals) = parsed.get("primals").and_then(|p| p.as_table()) {
        for (id, entry) in primals {
            primal_ids.insert(id.clone());

            let has_name = entry.get("name").and_then(|v| v.as_str()).is_some();
            let has_latest = entry.get("latest").and_then(|v| v.as_str()).is_some();
            let has_description = entry.get("description").and_then(|v| v.as_str()).is_some();

            if has_name && has_latest && has_description {
                passed += 1;
            } else {
                failed += 1;
                let missing: Vec<&str> = [
                    (!has_name).then_some("name"),
                    (!has_latest).then_some("latest"),
                    (!has_description).then_some("description"),
                ].into_iter().flatten().collect();
                eprintln!("  FAIL: primals.{id} missing: {}", missing.join(", "));
            }
        }
        println!("  PASS: {} primal entries in manifest", primal_ids.len());
        if primal_ids.len() < 13 {
            eprintln!("  WARN: expected at least 13 primals, found {}", primal_ids.len());
        }
    } else {
        failed += 1;
        eprintln!("  FAIL: no [primals.*] sections found");
    }

    // [atomics.*] sections
    if let Some(atomics) = parsed.get("atomics").and_then(|a| a.as_table()) {
        for (name, entry) in atomics {
            if let Some(primals_arr) = entry.get("primals").and_then(|p| p.as_array()) {
                for p in primals_arr {
                    if let Some(pname) = p.as_str() {
                        if !primal_ids.contains(pname) {
                            failed += 1;
                            eprintln!("  FAIL: atomics.{name} references unknown primal '{pname}'");
                        }
                    }
                }
                passed += 1;
            }
        }
        println!("  PASS: {} atomic definitions validated", atomics.len());
    }

    // [springs.*] sections
    if let Some(springs) = parsed.get("springs").and_then(|s| s.as_table()) {
        for id in springs.keys() {
            spring_ids.insert(id.clone());
        }
        println!("  PASS: {} spring entries in manifest", spring_ids.len());
        passed += 1;
    }

    ManifestReport { passed, failed, primal_ids, spring_ids }
}
