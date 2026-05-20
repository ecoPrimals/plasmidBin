// SPDX-License-Identifier: AGPL-3.0-or-later

//! Shared domain types for plasmidBin validation.

use std::fmt;

/// Expected minimum number of deployable primals in the ecosystem.
pub const MIN_PRIMALS: usize = 13;

/// Validation report aggregating pass/fail counts across phases.
#[derive(Debug, Default)]
pub struct Report {
    pub passed: usize,
    pub failed: usize,
}

impl Report {
    pub fn pass(&mut self, msg: &str) {
        self.passed += 1;
        println!("  PASS: {msg}");
    }

    pub fn fail(&mut self, msg: &str) {
        self.failed += 1;
        eprintln!("  FAIL: {msg}");
    }

    pub fn merge(&mut self, other: &Report) {
        self.passed += other.passed;
        self.failed += other.failed;
    }
}

impl fmt::Display for Report {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} passed, {} failed", self.passed, self.failed)
    }
}

/// Validate a BLAKE3 hex string (64 lowercase hex characters).
pub fn is_valid_blake3_hex(s: &str) -> bool {
    s.len() == 64 && s.bytes().all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn valid_blake3() {
        assert!(is_valid_blake3_hex(
            "6ca141176cab1d864bc507b9e257826125db8c5497245176e28d9e6dee7fa2c3"
        ));
    }

    #[test]
    fn rejects_uppercase() {
        assert!(!is_valid_blake3_hex(
            "6CA141176cab1d864bc507b9e257826125db8c5497245176e28d9e6dee7fa2c3"
        ));
    }

    #[test]
    fn rejects_short() {
        assert!(!is_valid_blake3_hex("6ca141176cab1d864bc507b9e25782"));
    }

    #[test]
    fn rejects_non_hex() {
        assert!(!is_valid_blake3_hex(
            "zca141176cab1d864bc507b9e257826125db8c5497245176e28d9e6dee7fa2c3"
        ));
    }

    #[test]
    fn report_display() {
        let r = Report { passed: 5, failed: 2 };
        assert_eq!(format!("{r}"), "5 passed, 2 failed");
    }
}
