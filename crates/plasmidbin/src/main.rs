// SPDX-License-Identifier: AGPL-3.0-or-later

//! `plasmidbin` — unified CLI for sovereign binary distribution.

#![allow(unsafe_code)]

mod cmd;

use clap::Parser;
use std::process::ExitCode;

#[derive(Parser)]
#[command(name = "plasmidbin", version, about = "Sovereign binary distribution CLI")]
struct Cli {
    #[command(subcommand)]
    command: cmd::Command,
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    match cli.command.run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("ERROR: {e:#}");
            ExitCode::FAILURE
        }
    }
}
