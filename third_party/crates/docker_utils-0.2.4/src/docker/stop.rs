/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The buildutils Authors and Contributors. All Rights Reserved.
 */

use crate::{DockerError, DockerUtil};

use std::process::Command;

impl DockerUtil {
    /// Stop a container
    ///
    /// # Arguments
    ///
    /// * `container_id` - The ID of the container to stop.
    ///
    /// # Returns
    ///
    /// Returns `Ok(())` if the container was successfully stopped, or `Err(DockerError)` if an error occurred.
    ///
    pub(crate) fn stop(&self, container_id: &str, delete: bool) -> Result<(), DockerError> {
        self.dbg_print("[stop_container]: Check if container exists.");
        let exists = self
            .check_if_container_is_running(container_id)
            .expect("Failed to check if container exists");

        if !exists {
            return Err(DockerError::from(format!(
                "Container doesn't exists: {container_id}"
            )));
        }

        if exists {
            let mut stop_cmd = Command::new("docker");
            match delete {
                // https://stackoverflow.com/questions/35122773/single-command-to-stop-and-remove-docker-container
                true => stop_cmd.arg("rm").arg("-f").arg(container_id.to_owned()),
                // https://spacelift.io/blog/docker-stop-container
                false => stop_cmd.arg("stop").arg(container_id.to_owned()),
            };

            self.dbg_print("[stop_container]: Container exists. Stopping it.");

            return match stop_cmd.status() {
                Ok(_) => Ok(()),
                Err(e) => Err(DockerError::from(format!(
                    "[stop_container]: Error stopping container {container_id}: {e}"
                ))),
            };
        }

        Ok(())
    }
}
