// SPDX-License-Identifier: AGPL-3.0-or-later

//! Canonical architecture enum — typed replacement for bash string matching.

use std::fmt;
use std::str::FromStr;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Arch {
    X86_64,
    Aarch64,
    Armv7,
}

impl Arch {
    /// Full Rust target triple for musl-static builds.
    pub fn triple(self) -> &'static str {
        match self {
            Arch::X86_64 => "x86_64-unknown-linux-musl",
            Arch::Aarch64 => "aarch64-unknown-linux-musl",
            Arch::Armv7 => "armv7-unknown-linux-musleabihf",
        }
    }

    /// Short name used in CLI and directory layouts.
    pub fn short(self) -> &'static str {
        match self {
            Arch::X86_64 => "x86_64",
            Arch::Aarch64 => "aarch64",
            Arch::Armv7 => "armv7",
        }
    }

    /// Detect architecture from the current host.
    pub fn detect() -> Result<Self, String> {
        #[cfg(target_arch = "x86_64")]
        return Ok(Arch::X86_64);
        #[cfg(target_arch = "aarch64")]
        return Ok(Arch::Aarch64);
        #[cfg(target_arch = "arm")]
        return Ok(Arch::Armv7);
        #[cfg(not(any(target_arch = "x86_64", target_arch = "aarch64", target_arch = "arm")))]
        return Err(format!("unsupported host architecture: {}", std::env::consts::ARCH));
    }

    /// Cross-compilation linker for this target.
    pub fn linker(self) -> Option<&'static str> {
        match self {
            Arch::X86_64 => None,
            Arch::Aarch64 => Some("aarch64-linux-gnu-gcc"),
            Arch::Armv7 => Some("arm-linux-gnueabihf-gcc"),
        }
    }

    /// Strip binary name for this architecture.
    pub fn strip_binary(self) -> &'static str {
        match self {
            Arch::X86_64 => "strip",
            Arch::Aarch64 => "aarch64-linux-gnu-strip",
            Arch::Armv7 => "arm-linux-gnueabihf-strip",
        }
    }

    /// All tier-1 architectures.
    pub fn tier1() -> &'static [Arch] {
        &[Arch::X86_64, Arch::Aarch64, Arch::Armv7]
    }

    /// Asset name for GitHub Releases: `{binary}-{triple}`.
    pub fn asset_name(self, binary: &str) -> String {
        format!("{binary}-{}", self.triple())
    }
}

impl FromStr for Arch {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "x86_64" | "x86_64-unknown-linux-musl" => Ok(Arch::X86_64),
            "aarch64" | "aarch64-unknown-linux-musl" => Ok(Arch::Aarch64),
            "armv7" | "armv7-unknown-linux-musleabihf" | "armv7l" => Ok(Arch::Armv7),
            _ => Err(format!("unsupported architecture: {s}")),
        }
    }
}

impl fmt::Display for Arch {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.triple())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_short() {
        assert_eq!("x86_64".parse::<Arch>().unwrap(), Arch::X86_64);
        assert_eq!("aarch64".parse::<Arch>().unwrap(), Arch::Aarch64);
        assert_eq!("armv7".parse::<Arch>().unwrap(), Arch::Armv7);
    }

    #[test]
    fn parse_full_triple() {
        assert_eq!("x86_64-unknown-linux-musl".parse::<Arch>().unwrap(), Arch::X86_64);
        assert_eq!("aarch64-unknown-linux-musl".parse::<Arch>().unwrap(), Arch::Aarch64);
        assert_eq!("armv7-unknown-linux-musleabihf".parse::<Arch>().unwrap(), Arch::Armv7);
    }

    #[test]
    fn rejects_unknown() {
        assert!("riscv64".parse::<Arch>().is_err());
    }

    #[test]
    fn round_trip() {
        for arch in Arch::tier1() {
            let s = arch.triple();
            assert_eq!(s.parse::<Arch>().unwrap(), *arch);
        }
    }

    #[test]
    fn asset_name() {
        assert_eq!(
            Arch::X86_64.asset_name("beardog"),
            "beardog-x86_64-unknown-linux-musl"
        );
    }
}
