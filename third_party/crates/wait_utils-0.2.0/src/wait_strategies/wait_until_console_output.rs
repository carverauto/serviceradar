/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The buildutils Authors and Contributors. All Rights Reserved.
 */

use crate::WaitStrategyError;
use crate::utils::utils_test::streams_contain;
use std::process::Command;
use std::time::Duration;
use tokio::time::Instant;

/// Waits until the console output of the container with the given ID contains the
/// specified expected output. If the expected output is not found within the given
/// timeout, an error is returned.
///
/// Both output streams of the container are searched, because `docker logs` keeps them
/// apart and many services report their readiness on stderr.
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

        if output.status.success()
            && streams_contain(&output.stdout, &output.stderr, expected_output)
        {
            if dbg {
                println!("Service online");
            }

            // Apparently, when the success log message appears in Docker,
            // some services still need more time to become ready.
            std::thread::sleep(Duration::from_millis(250));
            break;
        }
    }

    Ok(())
}

/// One-shot form of the console check: do the container's logs contain `expected_output`?
///
/// Exposed so a driver can compose the check with its own retry loop and keep checking
/// whatever else it knows about, such as whether the container is still alive. The looping
/// [`wait_until_console_output`] cannot do that, because it knows nothing but the container ID.
///
/// # Arguments
///
/// * `dbg` - Whether to print the outcome of the check.
/// * `container_id` - The ID of the container whose console output to check.
/// * `expected_output` - The string to search for in the console output.
///
/// # Returns
///
/// Returns whether either output stream contains the expected output. A container whose logs
/// cannot be read counts as not ready.
///
pub fn console_output_contains(dbg: bool, container_id: &str, expected_output: &str) -> bool {
    match Command::new("docker")
        .arg("logs")
        .arg(container_id)
        .output()
    {
        Ok(out) if out.status.success() => {
            streams_contain(&out.stdout, &out.stderr, expected_output)
        }
        Ok(out) => {
            if dbg {
                println!(
                    "[console_output_contains]: docker logs failed for {container_id}: {}",
                    String::from_utf8_lossy(&out.stderr).trim()
                );
            }
            false
        }
        Err(e) => {
            if dbg {
                println!("[console_output_contains]: failed to run docker logs: {e}");
            }
            false
        }
    }
}
