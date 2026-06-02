// SPDX-License-Identifier: AGPL-3.0-or-later

//! `plasmidbin stop` — stop primal processes locally or via SSH.

use anyhow::{Context, Result};
use clap::Args;
use plasmidbin_types::KNOWN_PRIMALS;

#[derive(Args)]
pub struct StopArgs {
    /// Remote gate (user@host) — if omitted, stops local primals
    gate: Option<String>,

    /// Remote plasmidBin directory (env: ECOPRIMALS_PLASMID_BIN)
    #[arg(long, default_value = super::defaults::DEFAULT_REMOTE_DIR, env = "ECOPRIMALS_PLASMID_BIN")]
    remote_dir: String,
}

pub fn run(args: StopArgs) -> Result<()> {
    if let Some(ref gate) = args.gate {
        println!("Stopping primals on {gate}...");
        let script = build_stop_script(&args.remote_dir);
        std::process::Command::new("ssh")
            .args([gate.as_str(), &script])
            .status()
            .context("SSH stop")?;
    } else {
        stop_local()?;
    }
    Ok(())
}

fn stop_local() -> Result<()> {
    println!("Stopping primals...");
    let mut stopped = 0u32;

    for name in KNOWN_PRIMALS {
        let pids = find_pids(name);
        for pid in &pids {
            let _ = signal_pid(*pid, "TERM");
            println!("  {name} (PID {pid}): stopped");
            stopped += 1;
        }
    }

    if stopped > 0 {
        std::thread::sleep(std::time::Duration::from_secs(1));

        // Force-kill any survivors
        for name in KNOWN_PRIMALS {
            let pids = find_pids(name);
            for pid in &pids {
                let _ = signal_pid(*pid, "KILL");
                println!("  {name} (PID {pid}): force killed");
            }
        }
    }

    clean_stale_sockets();
    println!("All primals stopped.");
    Ok(())
}

fn find_pids(name: &str) -> Vec<u32> {
    let output = std::process::Command::new("pgrep")
        .args(["-x", name])
        .output();
    match output {
        Ok(o) if o.status.success() => {
            String::from_utf8_lossy(&o.stdout)
                .lines()
                .filter_map(|l| l.trim().parse().ok())
                .collect()
        }
        _ => Vec::new(),
    }
}

fn signal_pid(pid: u32, signal: &str) -> bool {
    std::process::Command::new("kill")
        .args([&format!("-{signal}"), &pid.to_string()])
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn clean_stale_sockets() {
    let uid = super::current_uid();
    let dirs = [
        format!("/run/user/{uid}/biomeos"),
        format!("/run/user/{uid}/ecoprimals"),
        "/run/membrane".to_string(),
    ];
    let mut cleaned = 0;
    for dir in &dirs {
        let Ok(entries) = std::fs::read_dir(dir) else { continue };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().is_some_and(|e| e == "sock") {
                #[cfg(unix)]
                {
                    use std::os::unix::net::UnixStream;
                    if UnixStream::connect(&path).is_err() {
                        let _ = std::fs::remove_file(&path);
                        cleaned += 1;
                    }
                }
            }
        }
    }
    if cleaned > 0 {
        println!("Cleaned {cleaned} stale socket(s).");
    }
}

fn build_stop_script(remote_dir: &str) -> String {
    let names = KNOWN_PRIMALS.join(" ");
    format!(
        r#"for p in {names}; do
  pids=$(pgrep -f "{remote_dir}/primals/$p" 2>/dev/null) || true
  for pid in $pids; do kill $pid 2>/dev/null && echo "  $p ($pid): stopped"; done
done
sleep 1
for p in {names}; do
  pids=$(pgrep -f "{remote_dir}/primals/$p" 2>/dev/null) || true
  for pid in $pids; do kill -9 $pid 2>/dev/null; done
done
echo "All primals stopped.""#
    )
}
