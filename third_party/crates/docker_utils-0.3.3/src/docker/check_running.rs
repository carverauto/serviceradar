/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The buildutils Authors and Contributors. All Rights Reserved.
 */

use crate::{DockerError, DockerUtil};

impl DockerUtil {
    /// Check if a container is running
    ///
    /// # Arguments
    ///
    /// * `container_id` - The ID of the container to check
    ///
    /// # Returns
    ///
    /// Returns `Ok(true)` if the container is running, `Ok(false)` if it is not, or an `Err` if an error occurred
    ///
    /// The container ID is matched exactly, so `nginx-80` does not report `nginx-8080` as
    /// running, and it need not carry a `<name>-<port>` suffix.
    pub fn check_running(&self, container_id: &str) -> Result<bool, DockerError> {
        self.is_container_running(container_id)
    }
}
