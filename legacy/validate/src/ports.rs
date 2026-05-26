// SPDX-License-Identifier: AGPL-3.0-or-later

//! Typed validation for `ports.env` — canonical TCP port assignments and compositions.
//!
//! `ports.env` is a bash-sourceable file with three kinds of assignments:
//! - Port assignments: `VAR_PORT="${VAR_PORT:-PORT_NUM}"`
//! - Composition lists: `COMP_*="primal1 primal2 ..."`
//! - Niche lists: `NICHE_*="primal1 primal2 ..."`

use crate::types::Report;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::Path;

/// A parsed port assignment from `ports.env`.
#[derive(Debug)]
struct PortAssignment {
    var_name: String,
    port: u16,
}

/// A parsed composition definition from `ports.env`.
#[derive(Debug)]
struct CompositionDef {
    name: String,
    primals: Vec<String>,
}

#[allow(dead_code)]
pub struct PortsReport {
    pub report: Report,
    pub port_count: usize,
    pub port_map: BTreeMap<String, u16>,
    pub compositions: BTreeMap<String, Vec<String>>,
}

pub fn validate(root: &Path) -> PortsReport {
    let path = root.join("ports.env");
    let mut report = Report::default();
    let mut assignments: Vec<PortAssignment> = Vec::new();
    let mut compositions: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut port_map: BTreeMap<String, u16> = BTreeMap::new();

    let content = match std::fs::read_to_string(&path) {
        Ok(c) => c,
        Err(e) => {
            report.fail(&format!("cannot read {}: {e}", path.display()));
            return PortsReport { report, port_count: 0, port_map, compositions };
        }
    };

    for line in content.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }

        if let Some(pa) = parse_port_assignment(line) {
            assignments.push(pa);
        } else if let Some(comp) = parse_composition(line) {
            compositions.insert(comp.name.clone(), comp.primals);
        }
    }

    let mut ports_by_number: HashMap<u16, Vec<&str>> = HashMap::new();
    for pa in &assignments {
        if pa.port < 1024 {
            report.fail(&format!("{} = {} (privileged port, requires root)", pa.var_name, pa.port));
        }
        ports_by_number.entry(pa.port).or_default().push(&pa.var_name);
        let primal_name = var_to_primal(&pa.var_name);
        port_map.insert(primal_name, pa.port);
    }

    for (port, vars) in &ports_by_number {
        if vars.len() > 1 {
            report.fail(&format!("port {port} conflict: {}", vars.join(", ")));
        }
    }

    let unique_ports: BTreeSet<u16> = assignments.iter().map(|a| a.port).collect();
    if unique_ports.len() == assignments.len() && !assignments.is_empty() {
        report.pass(&format!("{} port assignments, no conflicts", assignments.len()));
    }

    if assignments.is_empty() {
        report.fail("no port assignments found in ports.env");
    }

    let assigned_primals: BTreeSet<String> = assignments.iter().map(|a| var_to_primal(&a.var_name)).collect();
    for (name, primals) in &compositions {
        for p in primals {
            if !assigned_primals.contains(p) && !p.starts_with('$') {
                report.fail(&format!("{name}: references '{p}' which has no port assignment"));
            }
        }
        report.pass(&format!("{name}: {} primals", primals.len()));
    }

    let port_count = assignments.len();
    PortsReport { report, port_count, port_map, compositions }
}

/// Parse `VAR_PORT="${VAR_PORT:-9100}"` into a `PortAssignment`.
fn parse_port_assignment(line: &str) -> Option<PortAssignment> {
    let (var, rhs) = line.split_once('=')?;
    let var = var.trim();
    if !var.ends_with("_PORT") {
        return None;
    }

    let port_str = rhs
        .trim()
        .trim_matches('"')
        .rsplit(":-")
        .next()?
        .trim_end_matches(['"', '}']);

    let port: u16 = port_str.parse().ok()?;

    Some(PortAssignment {
        var_name: var.to_owned(),
        port,
    })
}

/// Parse `COMP_TOWER="beardog songbird skunkbat"` or `NICHE_*` lines.
fn parse_composition(line: &str) -> Option<CompositionDef> {
    let (var, rhs) = line.split_once('=')?;
    let var = var.trim();

    if !var.starts_with("COMP_") && !var.starts_with("NICHE_") {
        return None;
    }

    let rhs = rhs.trim().trim_matches('"');
    if rhs.starts_with('$') {
        return None;
    }

    let primals: Vec<String> = rhs.split_whitespace().map(String::from).collect();
    if primals.is_empty() {
        return None;
    }

    Some(CompositionDef {
        name: var.to_owned(),
        primals,
    })
}

fn var_to_primal(var: &str) -> String {
    var.trim_end_matches("_PORT").to_lowercase()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_port_assignment() {
        let pa = parse_port_assignment(r#"BEARDOG_PORT="${BEARDOG_PORT:-9100}""#).unwrap();
        assert_eq!(pa.var_name, "BEARDOG_PORT");
        assert_eq!(pa.port, 9100);
    }

    #[test]
    fn parses_composition() {
        let comp = parse_composition(r#"COMP_TOWER="beardog songbird skunkbat""#).unwrap();
        assert_eq!(comp.name, "COMP_TOWER");
        assert_eq!(comp.primals, vec!["beardog", "songbird", "skunkbat"]);
    }

    #[test]
    fn parses_niche() {
        let niche = parse_composition(r#"NICHE_HOTSPRING="beardog songbird""#).unwrap();
        assert_eq!(niche.name, "NICHE_HOTSPRING");
        assert_eq!(niche.primals.len(), 2);
    }

    #[test]
    fn skips_variable_reference() {
        assert!(parse_composition(r#"COMP_NUCLEUS_FULL="$COMP_FULL""#).is_none());
    }

    #[test]
    fn skips_non_port_assignment() {
        assert!(parse_port_assignment(r#"ALL_PRIMALS="beardog songbird""#).is_none());
    }

    #[test]
    fn detects_port_conflict() {
        let mut report = Report::default();
        let mut ports_by_number: HashMap<u16, Vec<&str>> = HashMap::new();
        ports_by_number.entry(9100).or_default().push("A_PORT");
        ports_by_number.entry(9100).or_default().push("B_PORT");
        for (port, vars) in &ports_by_number {
            if vars.len() > 1 {
                report.fail(&format!("port {port} conflict: {}", vars.join(", ")));
            }
        }
        assert_eq!(report.failed, 1);
    }

    #[test]
    fn var_to_primal_works() {
        assert_eq!(var_to_primal("BEARDOG_PORT"), "beardog");
        assert_eq!(var_to_primal("SWEETGRASS_PORT"), "sweetgrass");
    }
}
