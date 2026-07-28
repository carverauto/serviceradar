/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The buildutils Authors and Contributors. All Rights Reserved.
 */

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

/// Builds a `docker ps` name filter that matches `container_id` and nothing else.
///
/// Docker matches the name filter as a regular expression anywhere within the name, so an
/// unanchored filter for `nginx-80` also matches `nginx-8080` and would report the wrong
/// container as running.
fn exact_name_filter(container_id: &str) -> String {
    // A dot is the only regular expression metacharacter Docker permits in a container name.
    format!("--filter=name=^{}$", container_id.replace('.', "\\."))
}

/// Extracts the port from a container ID of the form `<name>-<port>`.
///
/// Returns an error rather than panicking, because container IDs reach the public API
/// straight from the caller and need not carry a port suffix at all.
fn container_port_from_id(container_id: &str) -> Result<u16, DockerError> {
    container_id
        .rsplit('-')
        .next()
        .and_then(|port| port.trim().parse::<u16>().ok())
        .ok_or_else(|| {
            DockerError::from(format!(
                "[get_running_container]: Failed to read the port from container ID \
                 {container_id}. Expected an ID of the form <name>-<port>.",
            ))
        })
}

/// Extracts the tag from an image reference such as `nginx:1.27.0`.
///
/// A registry host may carry a port, as in `registry.io:5000/image`, so a colon only starts
/// a tag when no path separator follows it.
fn image_tag(image: &str) -> Option<&str> {
    let image = image.trim();
    let last_colon = image.rfind(':')?;

    if image[last_colon..].contains('/') {
        // The colon belongs to the registry host, so the reference carries no tag.
        return None;
    }

    Some(&image[last_colon + 1..])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_exact_name_filter_anchors_the_pattern() {
        // Without the anchors Docker also matches nginx-8080 for a nginx-80 lookup.
        assert_eq!(exact_name_filter("nginx-80"), "--filter=name=^nginx-80$");
    }

    #[test]
    fn test_exact_name_filter_escapes_dots() {
        // A dot is a regular expression wildcard and the only metacharacter Docker allows
        // in a container name.
        assert_eq!(
            exact_name_filter("my.app-80"),
            "--filter=name=^my\\.app-80$"
        );
    }

    #[test]
    fn test_container_port_from_id() {
        assert_eq!(container_port_from_id("nginx-80").unwrap(), 80);
        assert_eq!(container_port_from_id("my-app-8080").unwrap(), 8080);
        assert_eq!(container_port_from_id("postgres-5432").unwrap(), 5432);
    }

    #[test]
    fn test_container_port_from_id_without_port_suffix() {
        // Must report an error rather than panicking: container IDs arrive from the caller
        // and are not required to carry a port suffix.
        let res = container_port_from_id("redis");
        assert!(res.is_err());
        assert!(res.unwrap_err().to_string().contains("redis"));
    }

    #[test]
    fn test_container_port_from_id_rejects_out_of_range_port() {
        // 70000 does not fit a u16.
        assert!(container_port_from_id("service-70000").is_err());
    }

    #[test]
    fn test_container_port_from_id_rejects_empty_suffix() {
        assert!(container_port_from_id("service-").is_err());
    }

    #[test]
    fn test_image_tag() {
        assert_eq!(image_tag("nginx:1.27.0"), Some("1.27.0"));
        assert_eq!(image_tag("postgres:17-alpine3.20"), Some("17-alpine3.20"));
    }

    #[test]
    fn test_image_tag_trims_command_output() {
        // docker ps terminates its output with a newline.
        assert_eq!(image_tag("nginx:1.27.0\n"), Some("1.27.0"));
    }

    #[test]
    fn test_image_tag_of_registry_path() {
        assert_eq!(
            image_tag("asia-northeast1-docker.pkg.dev/project/repo/api:b422ae3"),
            Some("b422ae3")
        );
    }

    #[test]
    fn test_image_tag_ignores_registry_port() {
        // The colon introduces the registry port, not a tag, so there is no tag to report.
        assert_eq!(image_tag("registry.io:5000/image"), None);
        // With a tag present the registry port must not confuse the lookup.
        assert_eq!(image_tag("registry.io:5000/image:1.0"), Some("1.0"));
    }

    #[test]
    fn test_image_tag_of_untagged_image() {
        assert_eq!(image_tag("nginx"), None);
    }
}
