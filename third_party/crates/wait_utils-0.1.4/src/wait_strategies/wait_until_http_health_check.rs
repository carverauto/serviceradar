/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The buildutils Authors and Contributors. All Rights Reserved.
 */

use crate::WaitStrategyError;
use std::process::Command;
use std::time::Duration;
use tokio::time::Instant;

/// Waits until the health check URL responds successfully.
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
        cmd.arg(health_url);

        if let Ok(out) = cmd.output() {
            if dbg {
                println!(
                    "{}",
                    &format!(
                        "[wait_until_http_health_check]: \n
                    success: {} \n
                    Output: {}",
                        out.status.success(),
                        String::from_utf8_lossy(out.stdout.as_slice()),
                    )
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
