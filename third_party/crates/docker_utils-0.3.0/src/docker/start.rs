/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The buildutils Authors and Contributors. All Rights Reserved.
 */

use crate::{ContainerConfig, DockerError, DockerUtil};
use std::process::Command;
use wait_utils::WaitStrategy;

impl DockerUtil {
    /// Gets an existing container or starts a new one with the specified name, image, port, and reuse status.
    ///
    /// # Arguments
    ///
    /// * `name` - The name of the container.
    /// * `image` - The image to use for the container.
    /// * `port` - The port number for the container.
    /// * `reuse_container` - A boolean flag indicating whether to reuse an existing container if found.
    ///
    /// # Returns
    ///
    /// Returns a tuple containing the container name and port if successful, or a `DockerError` if an error occurs.
    ///
    pub(crate) fn get_or_start(
        &self,
        container_config: &ContainerConfig,
    ) -> Result<(String, u16), DockerError> {
        // Unpack values from container config
        let name = container_config.name();
        let image = &container_config.container_image();
        let connection_port = container_config.connection_port();
        let additional_ports = container_config.additional_ports();
        let platform = container_config.platform();
        let additional_env_vars = container_config.additional_env_vars();
        let reuse_container = container_config.reuse_container();
        let host_network = container_config.host_network();
        let wait_strategy = container_config.wait_strategy();

        let container_id = &format!("{name}-{connection_port}");

        println!("Container ID: {container_id}");

        self.dbg_print("Check if container is already running.");
        let is_running = self.check_if_container_is_running(container_id)?;

        if is_running {
            self.dbg_print("Container is already running.");
            if reuse_container {
                self.dbg_print("Re-using running container.");
                return self.get_running_container(container_id);
            }

            self.dbg_print("Container exists but re-use not wanted.");
            self.dbg_print("Stopping running container b/c no re-use wanted.");
            self.stop_container(container_id, true)?;
        } else {
            self.dbg_print("Container is NOT running.");
        }

        self.dbg_print("Check if container is starting.");
        let is_starting = self.check_if_container_is_starting(container_id)?;

        if is_starting {
            self.dbg_print("Container is already starting.");
            // Wait for the container to finish starting
            self.wait_for_container(container_id, wait_strategy)?;

            // Hand back the container that just came up. Falling through here would start a
            // second container under the same name, which Docker rejects.
            if self.check_if_container_is_running(container_id)? {
                return self.get_running_container(container_id);
            }

            self.dbg_print("Container is not running after waiting for it to start.");
        } else {
            self.dbg_print("Container is not starting.");
        }

        self.dbg_print("Container doesn't exist.");
        self.dbg_print("Pull container image.");
        match self.pull_container_image(container_id, image, platform) {
            Ok(()) => {}
            Err(e) => return Err(e),
        };

        self.dbg_print("Start new container.");
        match self.start_container(
            container_id,
            connection_port,
            additional_ports,
            platform,
            additional_env_vars,
            image,
            host_network,
            wait_strategy,
        ) {
            Ok((container_id, port)) => Ok((container_id, port)),
            Err(e) => Err(e),
        }
    }

    /// Starts a new Docker container with the specified configuration.
    ///
    /// # Arguments
    ///
    /// * `container_id` - The ID of the container.
    /// * `connection_port` - The port number for the main connection i.e. 80 for a webserver.
    /// * `additional_ports` - An optional array of additional ports to publish.
    /// * `platform` - An optional platform string in case the container image is not multi-arch.
    /// * `additional_env_vars` - An optional array of additional environment variables to set.
    /// * `image` - The image to use for the container.
    /// * `host_network` - Run the container on the host network instead of publishing ports.
    /// * `wait_strategy` - The wait strategy to use for the container.
    ///
    /// # Returns
    ///
    /// Returns a tuple containing the container name and port if successful,
    /// or a `DockerError` if an error occurs.
    ///
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn start_container(
        &self,
        container_id: &str,
        connection_port: u16,
        additional_ports: Option<&[u16]>,
        platform: Option<&str>,
        additional_env_vars: Option<&[&str]>,
        image: &str,
        host_network: bool,
        wait_strategy: &WaitStrategy,
    ) -> Result<(String, u16), DockerError> {
        // Example: docker run --rm --detach --publish 80:80 --name test-80 nginx:latest
        self.dbg_print(&format!(
            "[start_container]: Starting new container: {container_id}."
        ));

        let run_args = build_run_args(
            container_id,
            connection_port,
            additional_ports,
            platform,
            additional_env_vars,
            image,
            host_network,
        )?;

        // construct initial command
        let mut cmd = Command::new("docker");
        cmd.args(&run_args);

        self.dbg_print(&format!("[start_container]: Run Docker command: {cmd:?}"));

        // There are multiple ways to spawn a child process and execute an arbitrary command on the machine:
        //
        // spawn — runs the program and returns a value with details
        // output — runs the program and returns the output
        // status — runs the program and returns the exit code |  io::Result<ExitStatus>
        // https://stackoverflow.com/questions/21011330/how-do-i-invoke-a-system-command-and-capture-its-output

        // Run the command & return error in case of failure.
        //
        // A non-zero exit status must be surfaced as an error: otherwise `docker run` fails,
        // the cause is discarded, and the crate goes on to wait for a container that was
        // never started, reporting only the eventual wait timeout.
        match cmd.output() {
            Ok(out) if out.status.success() => {
                self.dbg_print(&format!(
                    "[start_container]: \n
                    success: true \n
                    Output: {}",
                    String::from_utf8_lossy(out.stdout.as_slice()),
                ));
            }
            Ok(out) => {
                return Err(DockerError::from(format!(
                    "Error starting container {container_id}: docker run failed (exit {:?}): {}",
                    out.status.code(),
                    String::from_utf8_lossy(out.stderr.as_slice()).trim(),
                )));
            }
            Err(e) => {
                return Err(DockerError::from(format!(
                    "Error starting container {container_id}: failed to spawn docker run: {e}"
                )));
            }
        };

        if self.dbg {
            // construct docker docker ps -a
            let mut cmd = Command::new("docker");
            cmd.arg("ps").arg("-a");

            self.dbg_print(&format!("[start_container]: Run Docker command: {cmd:?}"));

            match cmd.output() {
                Ok(out) => {
                    self.dbg_print(&format!(
                        "[start_container]: \n
                    success: {} \n
                    Output: {}",
                        out.status.success(),
                        String::from_utf8_lossy(out.stdout.as_slice()),
                    ));
                }
                Err(e) => {
                    return Err(DockerError::from(format!(
                        "Error running docker ps -a for container {container_id} due to error: {e}"
                    )));
                }
            };
        }

        match self.wait_for_container(container_id, wait_strategy) {
            Ok(()) => {}
            Err(e) => {
                return Err(e);
            }
        }
        //
        Ok((container_id.to_string(), connection_port))
    }

    /// Waits for a new Docker container to finish starting.
    ///
    /// # Arguments
    ///
    /// * `container_id` - The ID of the container.
    /// * `wait_strategy` - The wait strategy to use for the container.
    ///
    /// # Returns
    ///
    /// Returns Ok if successful,
    /// or a `DockerError` if an error occurs.
    pub(crate) fn wait_for_container(
        &self,
        container_id: &str,
        wait_strategy: &WaitStrategy,
    ) -> Result<(), DockerError> {
        match wait_strategy {
            WaitStrategy::WaitForDuration(duration) => {
                self.dbg_print(&format!(
                    "[start_container]: Waiting for {duration} seconds."
                ));
                wait_utils::wait_until_timeout(duration).expect("Failed to wait for duration");
                Ok(())
            }

            WaitStrategy::WaitUntilConsoleOutputContains(expected_output, timeout) => {
                self.dbg_print(&format!(
                    "[start_container]: Waiting until console output contains '{expected_output}'"
                ));
                wait_utils::wait_until_console_output(
                    self.dbg,
                    container_id,
                    expected_output,
                    timeout,
                )
                .expect("Failed to wait until console output contains");

                Ok(())
            }

            WaitStrategy::WaitForHttpHealthCheck(url, duration) => {
                self.dbg_print(&format!(
                    "[start_container]: Waiting for {:?} on HTTP health check on {}.",
                    duration, url
                ));
                wait_utils::wait_until_http_health_check(self.dbg, url, duration)
                    .expect("Failed to wait for HTTP health check");

                Ok(())
            }

            WaitStrategy::WaitForGrpcHealthCheck(_, _) => Err(DockerError::from(
                "WaitForGrpcHealthCheck for yet supported".to_string(),
            )),

            WaitStrategy::NoWait => {
                self.dbg_print("[start_container]: No wait. Return immediately.");
                // Do nothing
                Ok(())
            }
        }
    }
}

/// Builds the full argument list for `docker run`.
///
/// Kept separate from [`DockerUtil::start_container`] so that the argument construction,
/// in particular the host network / port publishing branch, can be verified without
/// invoking Docker.
///
/// # Arguments
///
/// * `container_id` - The ID of the container, also used as the container name.
/// * `connection_port` - The port number for the main connection i.e. 80 for a webserver.
/// * `additional_ports` - An optional array of additional ports to publish.
/// * `platform` - An optional platform string in case the container image is not multi-arch.
/// * `additional_env_vars` - An optional array of additional environment variables to set.
/// * `image` - The image to use for the container.
/// * `host_network` - Run the container on the host network instead of publishing ports.
///
/// # Returns
///
/// Returns the argument list if successful, or a `DockerError` if a port is invalid.
///
fn build_run_args(
    container_id: &str,
    connection_port: u16,
    additional_ports: Option<&[u16]>,
    platform: Option<&str>,
    additional_env_vars: Option<&[&str]>,
    image: &str,
    host_network: bool,
) -> Result<Vec<String>, DockerError> {
    let mut args = vec![
        "run".to_string(),
        "--rm".to_string(),
        "--detach".to_string(),
    ];

    if let Some(p) = platform {
        args.push("--platform".to_string());
        args.push(p.to_string());
    }

    // In host network mode the container shares the host's network namespace and binds the
    // host's ports directly. Docker discards any published port in that mode and warns about
    // it, so --publish is skipped entirely rather than passed and ignored.
    if host_network {
        args.push("--network".to_string());
        args.push("host".to_string());
    } else {
        // Format main connection port for docker
        args.push("--publish".to_string());
        args.push(format!("{connection_port}:{connection_port}"));
    }

    // Publish additional ports for the container, if applicable
    if let Some(additional_ports) = additional_ports {
        for port in additional_ports {
            // Validated regardless of network mode so that an invalid configuration is
            // reported rather than silently ignored on the host network.
            if *port == 0 {
                return Err(DockerError::from(format!(
                    "Error starting container {container_id}: Port cannot be 0.",
                )));
            }

            if !host_network {
                // Example: --publish 80:80
                args.push("--publish".to_string());
                args.push(format!("{port}:{port}"));
            }
        }
    }

    // Add container name
    args.push("--name".to_string());
    args.push(container_id.to_string());

    // Add env variables, if available. Docker takes a single value per -e flag, so each
    // variable needs its own flag; anything after the first would be read as the image name.
    if let Some(add_args) = additional_env_vars {
        for env_var in add_args {
            args.push("-e".to_string());
            args.push((*env_var).to_string());
        }
    }

    // Add container image to start
    args.push(image.to_string());

    Ok(args)
}

#[cfg(test)]
mod tests {
    use super::*;

    const CONTAINER_ID: &str = "test-8080";
    const IMAGE: &str = "test_image:latest";

    /// Builds args for a container publishing ports, with everything else unset.
    fn published_args() -> Vec<String> {
        build_run_args(CONTAINER_ID, 8080, None, None, None, IMAGE, false)
            .expect("Failed to build run args")
    }

    /// Builds args for the same container on the host network.
    fn host_network_args() -> Vec<String> {
        build_run_args(CONTAINER_ID, 8080, None, None, None, IMAGE, true)
            .expect("Failed to build run args")
    }

    /// Returns the value following `flag`, if any.
    fn value_after(args: &[String], flag: &str) -> Option<String> {
        let idx = args.iter().position(|a| a == flag)?;
        args.get(idx + 1).cloned()
    }

    /// Returns every value following an occurrence of `flag`.
    fn values_after(args: &[String], flag: &str) -> Vec<String> {
        args.iter()
            .enumerate()
            .filter(|(_, a)| a.as_str() == flag)
            .filter_map(|(i, _)| args.get(i + 1).cloned())
            .collect()
    }

    #[test]
    fn test_build_run_args_base_command() {
        let args = published_args();
        assert_eq!(args[0], "run");
        assert_eq!(args[1], "--rm");
        assert_eq!(args[2], "--detach");
        // The image is always the final argument.
        assert_eq!(args.last().unwrap(), IMAGE);
    }

    #[test]
    fn test_build_run_args_publishes_connection_port() {
        let args = published_args();
        assert_eq!(values_after(&args, "--publish"), vec!["8080:8080"]);
        assert!(!args.contains(&"--network".to_string()));
    }

    #[test]
    fn test_build_run_args_publishes_additional_ports() {
        let args = build_run_args(
            CONTAINER_ID,
            8080,
            Some(&[8081, 8082]),
            None,
            None,
            IMAGE,
            false,
        )
        .expect("Failed to build run args");

        assert_eq!(
            values_after(&args, "--publish"),
            vec!["8080:8080", "8081:8081", "8082:8082"]
        );
    }

    #[test]
    fn test_build_run_args_sets_container_name() {
        let args = published_args();
        assert_eq!(value_after(&args, "--name"), Some(CONTAINER_ID.to_string()));
    }

    #[test]
    fn test_build_run_args_sets_platform() {
        let args = build_run_args(
            CONTAINER_ID,
            8080,
            None,
            Some("linux/amd64"),
            None,
            IMAGE,
            false,
        )
        .expect("Failed to build run args");

        assert_eq!(
            value_after(&args, "--platform"),
            Some("linux/amd64".to_string())
        );
    }

    #[test]
    fn test_build_run_args_omits_platform_when_unset() {
        let args = published_args();
        assert!(!args.contains(&"--platform".to_string()));
    }

    #[test]
    fn test_build_run_args_gives_each_env_var_its_own_flag() {
        let args = build_run_args(
            CONTAINER_ID,
            8080,
            None,
            None,
            Some(&["ENV_VAR=VALUE", "DEBUG=true"]),
            IMAGE,
            false,
        )
        .expect("Failed to build run args");

        // Docker only reads one value per -e, so a shared flag would turn the second
        // variable into the image name.
        assert_eq!(
            values_after(&args, "-e"),
            vec!["ENV_VAR=VALUE", "DEBUG=true"]
        );
        assert_eq!(args.last().unwrap(), IMAGE);
    }

    #[test]
    fn test_build_run_args_host_network_sets_network_host() {
        let args = host_network_args();
        assert_eq!(value_after(&args, "--network"), Some("host".to_string()));
    }

    #[test]
    fn test_build_run_args_host_network_publishes_nothing() {
        let args = host_network_args();
        assert!(
            !args.contains(&"--publish".to_string()),
            "host network mode must not publish ports, got: {args:?}"
        );
    }

    #[test]
    fn test_build_run_args_host_network_skips_additional_ports() {
        let args = build_run_args(
            CONTAINER_ID,
            8080,
            Some(&[8081, 8082]),
            None,
            None,
            IMAGE,
            true,
        )
        .expect("Failed to build run args");

        assert!(
            !args.contains(&"--publish".to_string()),
            "host network mode must not publish additional ports, got: {args:?}"
        );
        assert_eq!(value_after(&args, "--network"), Some("host".to_string()));
    }

    #[test]
    fn test_build_run_args_host_network_keeps_other_arguments() {
        let args = build_run_args(
            CONTAINER_ID,
            8080,
            None,
            Some("linux/arm64"),
            Some(&["DEBUG=true"]),
            IMAGE,
            true,
        )
        .expect("Failed to build run args");

        assert_eq!(
            value_after(&args, "--platform"),
            Some("linux/arm64".to_string())
        );
        assert_eq!(value_after(&args, "--name"), Some(CONTAINER_ID.to_string()));
        assert_eq!(values_after(&args, "-e"), vec!["DEBUG=true"]);
        assert_eq!(args.last().unwrap(), IMAGE);
    }

    #[test]
    fn test_build_run_args_rejects_zero_port() {
        let res = build_run_args(CONTAINER_ID, 8080, Some(&[0]), None, None, IMAGE, false);
        assert!(res.is_err());
        assert!(res.unwrap_err().to_string().contains("Port cannot be 0"));
    }

    #[test]
    fn test_build_run_args_rejects_zero_port_on_host_network() {
        // Validation must not be skipped just because ports are not published.
        let res = build_run_args(CONTAINER_ID, 8080, Some(&[0]), None, None, IMAGE, true);
        assert!(res.is_err());
        assert!(res.unwrap_err().to_string().contains("Port cannot be 0"));
    }
}
