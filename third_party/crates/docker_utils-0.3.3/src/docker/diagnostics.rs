/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The buildutils Authors and Contributors. All Rights Reserved.
 */

use std::process::Command;

use crate::utils_test::{INSPECT_FORMAT, parse_inspect_line};
use crate::{ContainerDiagnostics, DockerError, DockerUtil};

impl DockerUtil {
    /// Collect a container's exit state and log tail.
    ///
    /// # Arguments
    ///
    /// * `container_id` - The ID of the container to inspect.
    /// * `log_tail` - How many trailing log lines to capture. Zero captures none.
    ///
    /// # Returns
    ///
    /// Returns the diagnostics, or a `DockerError` if the container could not be inspected,
    /// which is what happens once it has been removed.
    ///
    pub(crate) fn diagnostics(
        &self,
        container_id: &str,
        log_tail: usize,
    ) -> Result<ContainerDiagnostics, DockerError> {
        self.dbg_print(&format!(
            "[container_diagnostics]: Inspecting container: {container_id}."
        ));

        let inspect = Command::new("docker")
            .args([
                "inspect",
                "--type=container",
                "--format",
                INSPECT_FORMAT,
                container_id,
            ])
            .output()
            .map_err(|e| DockerError::from(format!("failed to run docker inspect: {e}")))?;

        if !inspect.status.success() {
            return Err(DockerError::from(format!(
                "docker inspect failed for '{container_id}': {}",
                String::from_utf8_lossy(&inspect.stderr).trim()
            )));
        }

        // Best effort, and deliberately not an error: a container can be inspectable while its
        // logs are already gone, and losing the tail is no reason to throw away the exit code,
        // which is the part that usually explains the failure.
        let logs = Command::new("docker")
            .args(["logs", "--tail", &log_tail.to_string(), container_id])
            .output()
            .ok()
            .filter(|out| out.status.success())
            .map(|out| {
                // Both streams: `docker logs` keeps them apart, and services built on glog
                // write everything to stderr.
                let stdout = String::from_utf8_lossy(&out.stdout);
                let stderr = String::from_utf8_lossy(&out.stderr);

                // Joined with a newline when needed: the two are captured separately and a
                // stdout tail that does not end in one would otherwise glue its last line
                // onto the first line of stderr.
                match (stdout.trim_end_matches('\n'), stderr.trim_end_matches('\n')) {
                    ("", err) => err.to_string(),
                    (out, "") => out.to_string(),
                    (out, err) => format!("{out}\n{err}"),
                }
            });

        let line = String::from_utf8_lossy(&inspect.stdout).to_string();

        parse_inspect_line(&line, logs)
    }
}
