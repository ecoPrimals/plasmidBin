// SPDX-License-Identifier: AGPL-3.0-or-later

use regex::Regex;
use std::collections::HashMap;
use std::path::Path;

pub struct PortsReport {
    pub passed: usize,
    pub failed: usize,
    pub port_count: usize,
}

pub fn validate(root: &Path) -> PortsReport {
    let path = root.join("ports.env");
    let mut passed = 0usize;
    let mut failed = 0usize;
    let mut ports: HashMap<u16, String> = HashMap::new();

    let content = match std::fs::read_to_string(&path) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("FAIL: cannot read {}: {e}", path.display());
            return PortsReport { passed: 0, failed: 1, port_count: 0 };
        }
    };

    // Match lines like: BEARDOG_PORT="${BEARDOG_PORT:-9100}"
    let port_re = Regex::new(r#"^([A-Z_]+_PORT)=.*:-(\d+)"#).unwrap();

    for line in content.lines() {
        let line = line.trim();
        if line.starts_with('#') || line.is_empty() {
            continue;
        }

        if let Some(caps) = port_re.captures(line) {
            let var = caps[1].to_string();
            let port_str = &caps[2];

            let port: u16 = match port_str.parse() {
                Ok(p) => p,
                Err(_) => {
                    failed += 1;
                    eprintln!("  FAIL: {var} has invalid port value: {port_str}");
                    continue;
                }
            };

            if port < 1024 {
                failed += 1;
                eprintln!("  FAIL: {var} = {port} (below 1024, requires root)");
            }

            if let Some(existing) = ports.get(&port) {
                failed += 1;
                eprintln!("  FAIL: port {port} conflict between {existing} and {var}");
            } else {
                ports.insert(port, var);
                passed += 1;
            }
        }
    }

    if ports.is_empty() {
        failed += 1;
        eprintln!("  FAIL: no port assignments found in ports.env");
    } else {
        println!("  PASS: {} port assignments, no conflicts", ports.len());
    }

    PortsReport { passed, failed, port_count: ports.len() }
}
