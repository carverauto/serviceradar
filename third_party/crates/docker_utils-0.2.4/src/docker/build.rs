/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The buildutils Authors and Contributors. All Rights Reserved.
 */

use crate::{DockerError, DockerUtil};
use std::process::{exit, Command};

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
                    println!();
                    println!(" ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️");
                    println!("🚨🚨🚨 DockerUtil: Mayday Mayday 🚨🚨🚨");
                    println!(" ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️");
                    println!("🚨🚨🚨 Cannot connect to Docker  🚨🚨🚨");
                    println!("🚨🚨🚨 Is Docker up & running?   🚨🚨🚨");
                    println!(" ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️");
                    println!("🚨🚨🚨 Help guide & documentation 🚨🚨🚨");
                    println!("Install Docker: https://docs.docker.com/engine/install/");
                    println!("Install Obstack: https://docs.orbstack.dev/quick-start");
                    exit(42)
                }
            }
            Err(e) => {
                return Err(DockerError::new(&format!(
                    "Failed to check if Docker is running due to error: {e}"
                )));
            }
        }

        Ok(Self { dbg })
    }
}
