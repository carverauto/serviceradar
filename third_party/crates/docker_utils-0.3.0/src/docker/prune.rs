/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The buildutils Authors and Contributors. All Rights Reserved.
 */

use crate::{DockerError, DockerUtil};
use std::process::Command;

impl DockerUtil {
    /// Prune all stopped containers, their associated volumes and networks.
    ///
    /// This method executes the `docker system prune` command with the `--all` and `--force` options
    /// to remove all stopped containers, their associated volumes, and networks.
    ///
    /// # Errors
    ///
    /// Returns a `DockerError` if there is an error executing the `docker system prune` command.
    /// Note that this waits for the prune to complete. Spawning without waiting would return
    /// before anything had been removed and would discard any failure reported by Docker.
    pub(crate) fn prune(&mut self) -> Result<(), DockerError> {
        match Command::new("docker")
            .arg("system")
            .arg("prune")
            .arg("--all")
            .arg("--force")
            .output()
        {
            Ok(out) if out.status.success() => Ok(()),
            Ok(out) => Err(DockerError::from(format!(
                "Error pruning containers: docker system prune failed (exit {:?}): {}",
                out.status.code(),
                String::from_utf8_lossy(&out.stderr).trim(),
            ))),
            Err(e) => Err(DockerError::from(format!("Error pruning containers: {e}"))),
        }
    }
}
