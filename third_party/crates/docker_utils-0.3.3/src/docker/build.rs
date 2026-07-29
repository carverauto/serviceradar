/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The buildutils Authors and Contributors. All Rights Reserved.
 */

use crate::{DockerError, DockerUtil};
use std::process::Command;

impl DockerUtil {
    /// Builds a new DockerUtil instance.
    ///
    /// Checks if Docker is running before returning the instance.
    /// If Docker is not running, it prints an error message and exits the program.
    pub(crate) fn build(dbg: bool) -> Result<Self, DockerError> {
        let mut cmd = Command::new("docker");
        cmd.arg("version");

        match cmd.output() {
            Ok(status) => {
                if status.status.code() == Some(0) {
                    if dbg {
                        println!("Status code: {}", status.status.code().unwrap());
                        println!("[DockerUtil]: Docker is running");
                    }
                } else {
                    // `docker` ran but exited non-zero, i.e. the daemon is unreachable.
                    //
                    // Reported rather than exited: a library must not terminate its caller's
                    // process, least of all on a remote executor where the exit code is the
                    // only artifact and no Result ever surfaces.
                    print_docker_help("Cannot connect to Docker", "Is Docker up & running?");
                    return Err(DockerError::new(&format!(
                        "Cannot connect to Docker (docker version exited {:?}): {}",
                        status.status.code(),
                        String::from_utf8_lossy(&status.stderr).trim()
                    )));
                }
            }
            Err(e) => {
                // `docker` could not be spawned at all, i.e. it is not on PATH.
                print_docker_help("Docker CLI was not found", "Is Docker installed?");
                return Err(DockerError::new(&format!(
                    "Failed to check if Docker is running due to error: {e}"
                )));
            }
        }

        Ok(Self { dbg })
    }
}

/// Prints the Docker help banner with a cause specific headline and hint.
fn print_docker_help(headline: &str, hint: &str) {
    println!();
    println!(" ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️");
    println!("🚨🚨🚨 {headline:<26} 🚨🚨🚨");
    println!("🚨🚨🚨 {hint:<26} 🚨🚨🚨");
    println!(" ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️");
    println!("🚨🚨🚨 Help guide & documentation 🚨🚨🚨");
    println!("Install Docker: https://docs.docker.com/engine/install/");
    println!("Install Orbstack: https://docs.orbstack.dev/quick-start");
}
