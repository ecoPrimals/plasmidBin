// SPDX-License-Identifier: AGPL-3.0-or-later

//! Typed domain models for plasmidBin metadata.
//!
//! Provides serde-typed parsing and validation for all plasmidBin data files:
//! `manifest.toml`, `checksums.toml`, `ports.env`, `sources.toml`.
//! Also provides the canonical `Arch` enum that eliminates string-based
//! architecture matching bugs.

#![forbid(unsafe_code)]

pub mod arch;
pub mod checksums;
pub mod manifest;
pub mod ports;
pub mod provenance;
pub mod sources;

mod report;
pub use report::Report;

pub const MIN_PRIMALS: usize = 13;

pub const KNOWN_PRIMALS: &[&str] = &[
    "beardog",
    "songbird",
    "skunkbat",
    "toadstool",
    "barracuda",
    "coralreef",
    "nestgate",
    "rhizocrypt",
    "loamspine",
    "sweetgrass",
    "biomeos",
    "squirrel",
    "petaltongue",
];

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
}
