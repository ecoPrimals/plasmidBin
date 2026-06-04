// SPDX-License-Identifier: AGPL-3.0-or-later

use std::fmt;

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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn report_display() {
        let r = Report {
            passed: 5,
            failed: 2,
        };
        assert_eq!(format!("{r}"), "5 passed, 2 failed");
    }
}
