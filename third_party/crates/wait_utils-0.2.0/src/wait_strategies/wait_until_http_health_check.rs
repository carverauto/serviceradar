/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The buildutils Authors and Contributors. All Rights Reserved.
 */

use crate::WaitStrategyError;
use crate::utils::utils_test::build_curl_args;
use std::process::Command;
use std::time::Duration;
use tokio::time::Instant;

/// Waits until the health check URL responds with a success status.
///
/// Only a status below 400 counts as ready. A service that is already listening but reports
/// itself as not ready, typically with a 503, keeps the wait going rather than ending it.
///
/// # Arguments
///
/// * `health_url` - The URL to ping for health check.
///
/// # Returns
///
/// Returns a `ServiceUtilError` if the healthcheck times out.
///
pub fn wait_until_http_health_check(
    dbg: bool,
    health_url: &str,
    timeout: &u64,
) -> Result<(), WaitStrategyError> {
    let start_time = Instant::now();
    let timeout = Duration::from_secs(*timeout);

    loop {
        std::thread::sleep(Duration::from_millis(100));

        if start_time.elapsed().as_secs() > timeout.as_secs() {
            return Err(WaitStrategyError(format!(
                "[wait_until_http_health_check]: !!Timeout!! Waited {} seconds for service health check",
                timeout.as_secs(),
            )));
        }

        let mut cmd = Command::new("curl");
        cmd.args(build_curl_args(health_url));

        if let Ok(out) = cmd.output() {
            if dbg {
                println!(
                    "[wait_until_http_health_check]: \n
                    success: {} \n
                    Error: {}",
                    out.status.success(),
                    String::from_utf8_lossy(out.stderr.as_slice()).trim(),
                );
            }

            if out.status.success() {
                if dbg {
                    println!("Service online");
                }

                break Ok(());
            }
        }
    }
}

/// One-shot form of the HTTP health check: does the URL answer with a success status?
///
/// Exposed so a driver can compose the check with its own retry loop and keep checking
/// whatever else it knows about, such as whether the container is still alive. The looping
/// [`wait_until_http_health_check`] cannot do that, because it knows nothing but the URL.
///
/// # Arguments
///
/// * `dbg` - Whether to print the outcome of the check.
/// * `health_url` - The URL to ping for health check.
///
/// # Returns
///
/// Returns whether the endpoint answered with a status below 400. Any failure to run curl at
/// all counts as not ready.
///
pub fn http_check_ok(dbg: bool, health_url: &str) -> bool {
    let mut cmd = Command::new("curl");
    cmd.args(build_curl_args(health_url));

    match cmd.output() {
        Ok(out) => {
            if dbg && !out.status.success() {
                println!(
                    "[http_check_ok]: {health_url} not ready: {}",
                    String::from_utf8_lossy(out.stderr.as_slice()).trim()
                );
            }
            out.status.success()
        }
        Err(e) => {
            if dbg {
                println!("[http_check_ok]: failed to run curl: {e}");
            }
            false
        }
    }
}
