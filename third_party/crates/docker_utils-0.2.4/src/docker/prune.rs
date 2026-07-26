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
    pub(crate) fn prune(&mut self) -> Result<(), DockerError> {
        match Command::new("docker")
            .arg("system")
            .arg("prune")
            .arg("--all")
            .arg("--force")
            .spawn()
        {
            Ok(_) => Ok(()),
            Err(e) => Err(DockerError::from(format!("Error pruning containers: {e}"))),
        }
    }
}
