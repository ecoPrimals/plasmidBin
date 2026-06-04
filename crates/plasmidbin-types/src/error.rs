// SPDX-License-Identifier: AGPL-3.0-or-later

//! Typed errors for plasmidBin domain models.

use std::path::PathBuf;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum TypesError {
    #[error("cannot read {path}: {source}")]
    ReadFile {
        path: PathBuf,
        source: std::io::Error,
    },

    #[error("cannot write {path}: {source}")]
    WriteFile {
        path: PathBuf,
        source: std::io::Error,
    },

    #[error("{file} schema error: {source}")]
    TomlParse {
        file: &'static str,
        source: toml::de::Error,
    },

    #[error("unsupported architecture: {arch}")]
    UnsupportedArch { arch: String },
}

pub type Result<T> = std::result::Result<T, TypesError>;
