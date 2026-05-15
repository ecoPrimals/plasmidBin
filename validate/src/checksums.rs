// SPDX-License-Identifier: AGPL-3.0-or-later

use regex::Regex;
use std::collections::BTreeSet;
use std::path::Path;

pub struct ChecksumReport {
    pub passed: usize,
    pub failed: usize,
    pub primal_ids: BTreeSet<String>,
}

pub fn validate(root: &Path, manifest_primals: &BTreeSet<String>) -> ChecksumReport {
    let path = root.join("checksums.toml");
    let mut passed = 0usize;
    let mut failed = 0usize;
    let mut primal_ids = BTreeSet::new();

    let content = match std::fs::read_to_string(&path) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("FAIL: cannot read {}: {e}", path.display());
            return ChecksumReport { passed: 0, failed: 1, primal_ids };
        }
    };

    let parsed: toml::Value = match toml::from_str(&content) {
        Ok(v) => {
            passed += 1;
            println!("  PASS: checksums.toml parses as valid TOML");
            v
        }
        Err(e) => {
            eprintln!("  FAIL: checksums.toml parse error: {e}");
            return ChecksumReport { passed, failed: failed + 1, primal_ids };
        }
    };

    let blake3_re = Regex::new(r"^[0-9a-f]{64}$").unwrap();

    if let Some(primals) = parsed.get("primals").and_then(|p| p.as_table()) {
        for (id, hashes) in primals {
            primal_ids.insert(id.clone());

            if let Some(table) = hashes.as_table() {
                let mut id_ok = true;
                for (triple, hash_val) in table {
                    if let Some(hash) = hash_val.as_str() {
                        if !blake3_re.is_match(hash) {
                            failed += 1;
                            id_ok = false;
                            eprintln!("  FAIL: primals.{id}.{triple} — invalid hash format: {hash}");
                        }
                    }
                }
                if id_ok {
                    passed += 1;
                }
            }
        }
        println!("  PASS: {} primals with checksums", primal_ids.len());
    } else {
        failed += 1;
        eprintln!("  FAIL: no [primals.*] sections in checksums.toml");
    }

    // Cross-check: every manifest primal should have checksums
    for mp in manifest_primals {
        if !primal_ids.contains(mp) {
            eprintln!("  WARN: manifest primal '{mp}' has no checksum entries");
        }
    }

    ChecksumReport { passed, failed, primal_ids }
}
