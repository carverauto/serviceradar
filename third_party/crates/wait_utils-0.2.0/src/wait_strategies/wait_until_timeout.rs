/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The buildutils Authors and Contributors. All Rights Reserved.
 */

use crate::WaitStrategyError;
use std::thread::sleep;
use std::time::Duration;

/// Waits for the given duration asynchronously.
///
/// # Arguments
///
/// * `wait_duration` - The duration to wait for.
///
/// # Returns
///
/// Returns Ok(()) when the wait is complete.
///
pub fn wait_until_timeout(timeout: &u64) -> Result<(), WaitStrategyError> {
    let timeout = Duration::from_secs(*timeout);
    sleep(timeout);
    Ok(())
}
