/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The buildutils Authors and Contributors. All Rights Reserved.
 */

use crate::{ContainerConfig, DockerError, DockerUtil};

impl DockerUtil {
    /// Create a new instance of the `DockerUtil` struct.
    ///
    /// # Returns
    ///
    /// Returns a new instance of the `DockerUtil` struct with default values.
    ///
    /// # Example
    ///
    /// ```no_run
    /// use docker_utils::{DockerUtil, ContainerConfig};
    /// use wait_utils::WaitStrategy;
    ///
    /// fn main() -> Result<(), Box<dyn std::error::Error>> {
    ///     let docker = DockerUtil::new()?;
    ///     Ok(())
    /// }
    /// ```
    ///
    pub fn new() -> Result<Self, DockerError> {
        // see src/docker/build.rs
        Self::build(false)
    }

    /// Create a new instance of the `DockerUtil` struct with debug mode enabled.
    ///
    /// # Returns
    ///
    /// Returns a `Result` containing a new instance of the `DockerUtil` struct with debug mode enabled, or a `DockerError` if an error occurred.
    ///
    /// # Example
    ///
    /// ```no_run
    /// use docker_utils::{DockerUtil, ContainerConfig};
    /// use wait_utils::WaitStrategy;
    ///
    /// fn main() -> Result<(), Box<dyn std::error::Error>> {
    ///     let docker = DockerUtil::with_debug()?;
    ///     Ok(())
    /// }
    /// ```
    ///
    pub fn with_debug() -> Result<Self, DockerError> {
        // see src/docker/build.rs
        Self::build(true)
    }

    /// Sets up a Docker container based on the provided configuration, handling existence checks and version management.
    ///
    /// # Arguments
    ///
    /// * `container_config` - Reference to a `ContainerConfig` containing the container configuration:
    ///   - Container name
    ///   - Image tag
    ///   - Other container-specific settings
    ///
    /// # Returns
    ///
    /// Returns a `Result<(String, u16), DockerError>`:
    /// * `Ok((container_name, port))` - A tuple containing:
    ///   - `container_name`: String - The name of the running container
    ///   - `port`: u16 - The exposed port number of the container
    /// * `Err(DockerError)` - If any Docker operation fails
    ///
    /// # Example
    ///
    /// ```no_run
    /// use docker_utils::{DockerUtil, ContainerConfig};
    /// use wait_utils::WaitStrategy;
    ///
    /// fn main() -> Result<(), Box<dyn std::error::Error>> {
    ///     let docker = DockerUtil::new()?;
    ///
    ///     let config = ContainerConfig::new(
    ///         "postgres",
    ///         "postgres",
    ///         "14",
    ///         "0.0.0.0",
    ///         5432,
    ///         None,
    ///         Some(&["POSTGRES_PASSWORD=secret"]),
    ///         None,
    ///         true,
    ///         false,
    ///         WaitStrategy::WaitUntilConsoleOutputContains(
    ///             "PostgreSQL init process complete; ready for start up.".to_string(),
    ///             15,
    ///         ),
    ///     );
    ///
    ///     let (container_name, port) = docker.setup_container(&config)?;
    ///     println!("Container {} running on port {}", container_name, port);
    ///     Ok(())
    /// }
    /// ```
    ///
    /// # Errors
    ///
    /// Returns a `DockerError` if:
    /// * Container existence check fails
    /// * Container tag verification fails
    /// * Container stop operation fails (when tag mismatch)
    /// * Container start operation fails
    /// * Port mapping operation fails
    /// * Docker API communication fails
    ///
    /// # Panics
    ///
    /// This function will panic if:
    /// * Container existence check critically fails
    /// * Tag verification critically fails
    /// * Container stop operation critically fails
    /// * Container setup critically fails
    ///
    /// # Implementation Notes
    ///
    /// This function performs the following steps:
    /// 1. Checks if a container with the given name already exists
    /// 2. If exists, verifies if it uses the target tag
    /// 3. If tag mismatch, stops the existing container
    /// 4. Creates or reuses the container with correct configuration
    /// 5. Returns the container name and exposed port
    ///
    pub fn setup_container(
        &self,
        container_config: &ContainerConfig<'_>,
    ) -> Result<(String, u16), DockerError> {
        // see src/docker/setup.rs
        self.setup(container_config)
    }
    /// Gets an existing container or starts a new one with the specified configuration
    ///
    /// # Arguments
    ///
    /// * `container_config` - The configuration of the container.
    ///
    /// # Returns
    ///
    /// Returns a tuple containing the container name and port if successful,
    /// or a `DockerError` if an error occurs.
    ///
    /// # Example
    ///
    /// ```no_run
    /// use docker_utils::{DockerUtil, ContainerConfig};
    /// use wait_utils::WaitStrategy;
    ///
    /// fn main() -> Result<(), Box<dyn std::error::Error>> {
    ///     let docker = DockerUtil::new()?;
    ///
    ///     let config = ContainerConfig::new(
    ///         "redis",
    ///         "redis",
    ///         "latest",
    ///         "0.0.0.0",
    ///         6379,
    ///         None,
    ///         None,
    ///         None,
    ///         true,
    ///         false,
    ///         WaitStrategy::default(),
    ///     );
    ///
    ///     let (container_name, port) = docker.get_or_start_container(&config)?;
    ///     println!("Redis container {} available on port {}", container_name, port);
    ///     Ok(())
    /// }
    /// ```
    ///
    pub fn get_or_start_container(
        &self,
        container_config: &ContainerConfig,
    ) -> Result<(String, u16), DockerError> {
        // see src/docker/start.rs
        self.get_or_start(container_config)
    }
    /// Check if a container exists by its ID.
    ///
    /// # Arguments
    ///
    /// * `container_id` - The ID of the container to check.
    ///
    /// # Returns
    ///
    /// Returns `Ok(true)` if the container exists, `Ok(false)` if the container does not exist, or `Err(DockerError)` if an error occurred.
    ///
    /// # Example
    ///
    /// ```no_run
    /// use docker_utils::DockerUtil;
    ///
    /// fn main() -> Result<(), Box<dyn std::error::Error>> {
    ///     let docker = DockerUtil::new()?;
    ///
    ///     let container_id = "redis-6379";  // Example container ID
    ///     match docker.check_if_container_is_running(container_id)? {
    ///         true => println!("Container {} is running", container_id),
    ///         false => println!("Container {} is not running", container_id),
    ///     }
    ///     Ok(())
    /// }
    /// ```
    ///
    pub fn check_if_container_is_running(&self, container_id: &str) -> Result<bool, DockerError> {
        // see src/docker/check_running.rs
        self.check_running(container_id)
    }
    /// Stop a container
    ///
    /// # Arguments
    ///
    /// * `container_id` - The ID of the container to stop.
    /// * `delete` - Whether to delete the container after stopping.
    ///
    /// # Returns
    ///
    /// Returns `Ok(())` if the container was successfully stopped, or `Err(DockerError)` if an error occurred.
    ///
    /// # Example
    ///
    /// ```no_run
    /// use docker_utils::DockerUtil;
    ///
    /// fn main() -> Result<(), Box<dyn std::error::Error>> {
    ///     let docker = DockerUtil::new()?;
    ///
    ///     let container_id = "redis-6379";  // Example container ID
    ///     let delete_container = false;
    ///     docker.stop_container(container_id, delete_container)?;
    ///     println!("Container {} stopped successfully", container_id);
    ///     Ok(())
    /// }
    /// ```
    ///
    pub fn stop_container(&self, container_id: &str, delete: bool) -> Result<(), DockerError> {
        // see src/docker/stop.rs
        self.stop(container_id, delete)
    }
    /// Pulls a container image from a registry.
    ///
    /// This method pulls a container image from a specified registry using the `docker pull` command.
    ///
    /// # Arguments
    ///
    /// * `container_id` - The ID of the container to start.
    /// * `image` - The container image with tag.
    /// * `platform` - Optional platform tag, such as linux/amd64.
    ///
    /// # Returns
    ///
    /// * `Result<(), DockerError>` - Returns `Ok(())` if the image is pulled successfully, or an `Err` containing the error if it fails.
    ///
    /// # Example
    ///
    /// ```no_run
    /// use docker_utils::DockerUtil;
    ///
    /// fn main() -> Result<(), Box<dyn std::error::Error>> {
    ///     let docker = DockerUtil::new()?;
    ///
    ///     // Pull image for specific platform
    ///     docker.pull_container_image(
    ///         "nginx-container",
    ///         "nginx:latest",
    ///         Some("linux/amd64")
    ///     )?;
    ///
    ///     // Pull image without platform specification
    ///     docker.pull_container_image(
    ///         "redis-container",
    ///         "redis:latest",
    ///         None
    ///     )?;
    ///
    ///     Ok(())
    /// }
    /// ```
    ///
    /// # Errors
    ///
    /// Returns a `DockerError` if there is an error pulling the container image.
    ///
    pub fn pull_container_image(
        &self,
        container_id: &str,
        image: &str,
        platform: Option<&str>,
    ) -> Result<(), DockerError> {
        // see src/docker/pull.rs
        self.pull(container_id, image, platform)
    }
    /// Prunes all stopped containers and their associated volumes and networks.
    ///
    /// This method executes the `docker system prune` command with the `--all` and `--force` options to remove all stopped containers, their associated volumes, and networks.
    ///
    /// # Returns
    ///
    /// * `Result<(), DockerError>` - Returns `Ok(())` if the containers are pruned successfully, or an `Err` containing the error if it fails.
    ///
    /// # Example
    ///
    /// ```no_run
    /// use docker_utils::DockerUtil;
    ///
    /// fn main() -> Result<(), Box<dyn std::error::Error>> {
    ///     let mut docker = DockerUtil::new()?;
    ///
    ///     // Clean up all stopped containers and their resources
    ///     docker.prune_all_containers()?;
    ///     println!("Successfully pruned all stopped containers");
    ///     Ok(())
    /// }
    /// ```
    ///
    /// # Errors
    ///
    /// Returns a `DockerError` if there is an error executing the `docker system prune` command.
    ///
    pub fn prune_all_containers(&mut self) -> Result<(), DockerError> {
        // see src/docker/prune.rs
        self.prune()
    }
}
