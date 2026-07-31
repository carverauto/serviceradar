/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The buildutils Authors and Contributors. All Rights Reserved.
 */

use crate::utils_test::{container_port_from_id, exact_name_filter, image_tag};
use crate::{DockerError, DockerUtil};

use std::process::Command;

impl DockerUtil {
    /// Check if a container is starting.
    ///
    /// # Arguments
    ///
    /// * `container_id` - The ID of the container to check.
    ///
    /// # Returns
    ///
    /// Returns `Ok(true)` if the container is starting, `Ok(false)` if the container is not starting, or `Err(DockerError)` if an error occurred.
    ///
    pub(crate) fn check_if_container_is_starting(
        &self,
        container_id: &str,
    ) -> Result<bool, DockerError> {
        self.dbg_print(&format!(
            "[check_if_container_is_starting]: Check container image for: {container_id}."
        ));

        // Example docker logs apiproxy-7777
        match Command::new("docker")
            .arg("logs")
            .arg(container_id)
            .output()
        {
            Ok(out) => {
                self.dbg_print(&format!(
                    "[check_if_container_is_starting]: \n
                    success: {} \n
                    Output: {}",
                    out.status.success(),
                    String::from_utf8_lossy(out.stdout.as_slice()),
                ));

                if out.status.success() {
                    if out.stdout.is_empty() {
                        Ok(false)
                    } else {
                        Ok(true)
                    }
                } else {
                    Ok(false)
                }
            }
            Err(_) => Ok(false),
        }
    }

    /// Check whether a container with exactly this ID is running.
    ///
    /// Unlike [`DockerUtil::get_running_container`] this does not require the ID to carry a
    /// port suffix, so it is safe to call for arbitrary container names.
    ///
    /// # Arguments
    ///
    /// * `container_id` - The ID of the container to check.
    ///
    /// # Returns
    ///
    /// Returns whether the container is running, or a `DockerError` if `docker ps` failed.
    ///
    pub(crate) fn is_container_running(&self, container_id: &str) -> Result<bool, DockerError> {
        let mut cmd = Command::new("docker");
        cmd.arg("ps");
        cmd.arg("--filter=status=running");
        cmd.arg(exact_name_filter(container_id));
        cmd.arg("--format={{.Names}}");

        self.dbg_print(&format!(
            "[is_container_running]: Run Docker command: {cmd:?}"
        ));

        match cmd.output() {
            Ok(out) if out.status.success() => {
                let names = String::from_utf8_lossy(&out.stdout);
                Ok(!names.trim().is_empty())
            }
            Ok(out) => Err(DockerError::from(format!(
                "[is_container_running]: docker ps failed for {container_id} (exit {:?}): {}",
                out.status.code(),
                String::from_utf8_lossy(&out.stderr).trim(),
            ))),
            Err(e) => Err(DockerError::from(format!(
                "[is_container_running]: Error getting container {container_id}: {e}"
            ))),
        }
    }

    /// Get the the name and of about a running container by its ID.
    ///
    /// # Arguments
    ///
    /// * `container_id` - The ID of the container to retrieve information about.
    ///
    /// # Returns
    ///
    /// Either returns the name and port of a container if its running, otherwise an `DockerError`.
    /// The container ID must be of the form `<name>-<port>`, because the port is read from it.
    ///
    pub(crate) fn get_running_container(
        &self,
        container_id: &str,
    ) -> Result<(String, u16), DockerError> {
        self.dbg_print(&format!(
            "[get_running_container]: Check container image for: {container_id}."
        ));

        if !self.is_container_running(container_id)? {
            return Err(DockerError::from(format!(
                "[get_running_container]: Error no container found for ID: {container_id}",
            )));
        }

        let port = container_port_from_id(container_id)?;

        Ok((container_id.to_string(), port))
    }

    /// Checks if a running container uses a specific target tag.
    ///
    /// This method takes a container ID and a target tag as input and checks if the running container with the given ID uses the target tag.
    /// It first retrieves the image tag of the running container using the `get_running_container_image_tag` method.
    /// Then it compares the retrieved image tag with the target tag provided.
    ///
    /// # Arguments
    ///
    /// * `&self` - A reference to the `DockerUtil` object.
    /// * `container_id` - The ID of the container to check.
    /// * `target_tag` - The target tag to compare with the container's image tag.
    ///
    /// # Returns
    ///
    /// * `Result<bool, DockerError>` - Returns `Ok(true)` if the container uses the target tag, `Ok(false)` if it does not, or an [Err](cci:4:///Users/marvin/RustroverProjects/quant-engine/queng_utils/env_utils/src/ci/setup_containers.rs:98:0-118:0) containing the error.
    ///
    /// # Errors
    ///
    /// Returns a `DockerError` if there is an error getting the container image tag or if the comparison fails.
    ///
    pub(crate) fn check_if_running_container_uses_target_tag(
        &self,
        container_id: &str,
        target_tag: &str,
    ) -> Result<bool, DockerError> {
        match self.get_running_container_image_tag(container_id) {
            Ok(container_tag) => Ok(container_tag.eq_ignore_ascii_case(target_tag)),
            Err(e) => Err(DockerError::from(format!(
                "[check_if_container_uses_target_tag]: Error getting container_tag for container ID: {container_id} {e}"
            ))),
        }
    }

    /// Retrieves the image tag of a running container by its ID.
    ///
    /// This method takes a container ID as input and retrieves the image tag of the running container.
    /// It first checks if the container exists using the `check_if_container_exists` method.
    /// If the container exists, it executes the `docker ps` command with the `--filter` option to get the container image.
    /// The image tag is extracted from the output of the `docker ps` command.
    ///
    /// # Arguments
    ///
    /// * `&self` - A reference to the `DockerUtil` object.
    /// * `container_id` - The ID of the container for which the image tag is to be retrieved.
    ///
    /// # Returns
    ///
    /// * `Result<String, DockerError>` - The image tag of the running container as a string. Returns `Ok(tag)` if the image tag is retrieved successfully, or an `Err` containing the error if it fails.
    ///
    /// # Errors
    ///
    /// Returns a `DockerError` if the container does not exist or if there is an error executing the `docker ps` command.
    ///
    pub(crate) fn get_running_container_image_tag(
        &self,
        container_id: &str,
    ) -> Result<String, DockerError> {
        if !self.is_container_running(container_id)? {
            return Err(DockerError::from(format!(
                "[get_running_container_image_tag]: Error no container found for ID: {container_id}",
            )));
        }

        let mut cmd = Command::new("docker");
        cmd.arg("ps");
        cmd.arg(exact_name_filter(container_id));
        cmd.arg("--format={{.Image}}");

        self.dbg_print(&format!(
            "[get_container_image_tag]: Run Docker command: {cmd:?}"
        ));

        let container_image = match cmd.output() {
            Ok(out) if out.status.success() => String::from_utf8_lossy(&out.stdout).to_string(),
            Ok(out) => {
                return Err(DockerError::from(format!(
                    "[get_container_image_tag]: docker ps failed for {container_id} (exit {:?}): {}",
                    out.status.code(),
                    String::from_utf8_lossy(&out.stderr).trim(),
                )));
            }
            Err(e) => {
                return Err(DockerError::from(format!(
                    "[get_container_image_tag]: Error getting container image for {container_id}: {e}"
                )));
            }
        };

        if container_image.trim().is_empty() {
            return Err(DockerError::from(format!(
                "[get_container_image_tag]: Error no image found for container ID: {container_id}",
            )));
        }

        image_tag(&container_image)
            .map(ToOwned::to_owned)
            .ok_or_else(|| {
                DockerError::from(format!(
                    "[get_container_image_tag]: Image {} for container ID {container_id} carries no tag",
                    container_image.trim(),
                ))
            })
    }
}
