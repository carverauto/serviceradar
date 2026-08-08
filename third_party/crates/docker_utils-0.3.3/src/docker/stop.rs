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
        let exists = self.check_if_container_is_running(container_id)?;

        if !exists {
            // Already gone is the requested end state when deleting, and `--rm` guarantees it
            // after a crash, so erroring here would mask the real failure with a teardown one.
            // Without `delete` the caller asked to stop a specific container, so an absent one
            // is still reported.
            if delete {
                self.dbg_print(&format!(
                    "[stop_container]: Container {container_id} is already gone."
                ));
                return Ok(());
            }

            return Err(DockerError::from(format!(
                "Container doesn't exists: {container_id}"
            )));
        }

        let mut stop_cmd = Command::new("docker");
        match delete {
            // https://stackoverflow.com/questions/35122773/single-command-to-stop-and-remove-docker-container
            true => stop_cmd.arg("rm").arg("-f").arg(container_id),
            // https://spacelift.io/blog/docker-stop-container
            false => stop_cmd.arg("stop").arg(container_id),
        };

        self.dbg_print("[stop_container]: Container exists. Stopping it.");

        // The exit status must be checked: otherwise a container that failed to stop is
        // reported as stopped, and the caller carries on against a container still running.
        match stop_cmd.output() {
            Ok(out) if out.status.success() => Ok(()),
            Ok(out) => Err(DockerError::from(format!(
                "[stop_container]: Failed to stop container {container_id} (exit {:?}): {}",
                out.status.code(),
                String::from_utf8_lossy(&out.stderr).trim(),
            ))),
            Err(e) => Err(DockerError::from(format!(
                "[stop_container]: Error stopping container {container_id}: {e}"
            ))),
        }
    }
}
