/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The buildutils Authors and Contributors. All Rights Reserved.
 */

use crate::WaitStrategyError;
use std::process::Command;
use std::time::Duration;
use tokio::time::Instant;

/// Waits until the console output of the container with the given ID contains the
/// specified expected output. If the expected output is not found within the given
/// timeout, an error is returned.
///
/// # Arguments
///
/// * `container_id` - The ID of the container whose console output to check.
/// * `expected_output` - The string to search for in the console output.
/// * `timeout` - The timeout duration in seconds.
///
/// # Returns
///
/// Returns `Ok(())` if the expected output is found within the timeout, or an
/// `Err(DockerError)` if the expected output is not found.
///
pub fn wait_until_console_output(
    dbg: bool,
    container_id: &str,
    expected_output: &str,
    timeout: &u64,
) -> Result<(), WaitStrategyError> {
    let start_time = Instant::now();
    let timeout = Duration::from_secs(*timeout);

    loop {
        std::thread::sleep(Duration::from_millis(100));

        if start_time.elapsed() > timeout {
            return Err(WaitStrategyError::from(format!(
                "[start_container]: !!Timeout!! Waited {} seconds for console output to contain {}",
                timeout.as_secs(),
                expected_output
            )));
        }

        // Example: docker logs apiproxy-7777
        // https://docs.docker.com/reference/cli/docker/container/logs/
        let output = Command::new("docker")
            .arg("logs")
            .arg(container_id)
            .output()
            .map_err(|e| {
                WaitStrategyError::from(format!(
                    "[start_container]: Failed to run docker logs for container: {container_id} Error: {e}"
                ))
            })?;

        if output.status.success() {
            if dbg {
                println!("Service online");
            }
            if String::from_utf8_lossy(&output.stdout).contains(expected_output) {
                // Apparently, when the success log message appears in Docker,
                // some services still need more time to become ready.
                std::thread::sleep(Duration::from_millis(250));
                break;
            }
        }
    }

    Ok(())
}
