/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The buildutils Authors and Contributors. All Rights Reserved.
 */

use crate::utils_test::build_run_args;
use crate::{ContainerConfig, DockerError, DockerUtil};
use std::process::Command;
use std::time::Duration;
use wait_utils::{Probe, ProbeContext, ProbeFn, WaitStrategy};

/// How often the built-in strategies re-check, and therefore how often a container that died
/// mid-wait is noticed.
const POLL_INTERVAL: Duration = Duration::from_millis(250);

/// How long to let a service settle after it logs that it is ready.
const CONSOLE_SETTLE_DELAY: Duration = Duration::from_millis(250);

/// How many log lines to attach to a wait failure.
const WAIT_FAILURE_LOG_TAIL: usize = 200;

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
        let host = container_config.url();
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

                // A running container is not a ready one. With recycled runners a container
                // left behind by a killed run would otherwise be handed straight back, and
                // moving readiness into the strategy would quietly lose the gate on exactly
                // the runner where it matters.
                self.wait_for_container(container_id, host, connection_port, wait_strategy)?;

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
            self.wait_for_container(container_id, host, connection_port, wait_strategy)?;

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
            host,
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
    /// * `host` - The host a caller would connect to, handed to a readiness probe.
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
        host: &str,
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

        match self.wait_for_container(container_id, host, connection_port, wait_strategy) {
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
    /// Whatever the strategy, the container is checked for liveness between attempts, and any
    /// failure carries the container's post-mortem. An OOM kill two seconds into a two minute
    /// wait would otherwise be reported as a timeout, which is the symptom and not the cause.
    ///
    /// # Arguments
    ///
    /// * `container_id` - The ID of the container.
    /// * `host` - The host a caller would connect to, handed to a readiness probe.
    /// * `port` - The port a caller would connect to, handed to a readiness probe.
    /// * `wait_strategy` - The wait strategy to use for the container.
    ///
    /// # Returns
    ///
    /// Returns Ok if successful, or a `DockerError` carrying the reason and the container's
    /// diagnostics if an error occurs.
    pub(crate) fn wait_for_container(
        &self,
        container_id: &str,
        host: &str,
        port: u16,
        wait_strategy: &WaitStrategy,
    ) -> Result<(), DockerError> {
        match self.run_wait_strategy(container_id, host, port, wait_strategy) {
            Ok(()) => Ok(()),
            Err(e) => Err(self.explain_wait_failure(container_id, &e.0)),
        }
    }

    /// Dispatches the strategy, without the post-mortem the caller sees.
    fn run_wait_strategy(
        &self,
        container_id: &str,
        host: &str,
        port: u16,
        wait_strategy: &WaitStrategy,
    ) -> Result<(), DockerError> {
        match wait_strategy {
            WaitStrategy::NoWait => {
                self.dbg_print("[wait_for_container]: No wait. Return immediately.");
                Ok(())
            }

            WaitStrategy::WaitForDuration(duration) => {
                self.dbg_print(&format!(
                    "[wait_for_container]: Waiting for {duration} seconds."
                ));
                // A fixed sleep has nothing to poll, so there is no liveness check to make.
                wait_utils::wait_until_timeout(duration).map_err(|e| {
                    DockerError::from(format!(
                        "container '{container_id}' could not be waited for: {e}"
                    ))
                })
            }

            WaitStrategy::WaitUntilConsoleOutputContains(expected_output, timeout) => {
                self.dbg_print(&format!(
                    "[wait_for_container]: Waiting until console output contains '{expected_output}'"
                ));
                self.poll_until(container_id, Duration::from_secs(*timeout), || {
                    if wait_utils::console_output_contains(self.dbg, container_id, expected_output)
                    {
                        Probe::Ready(())
                    } else {
                        Probe::Retry(format!(
                            "console output does not yet contain '{expected_output}'"
                        ))
                    }
                })?;

                // Apparently, when the success log message appears in Docker, some services
                // still need more time to become ready. Kept from the looping strategy this
                // replaced, because dropping it would make previously working setups flaky.
                std::thread::sleep(CONSOLE_SETTLE_DELAY);

                Ok(())
            }

            WaitStrategy::WaitForHttpHealthCheck(url, timeout) => {
                self.dbg_print(&format!(
                    "[wait_for_container]: Waiting up to {timeout}s on HTTP health check on {url}."
                ));
                self.poll_until(container_id, Duration::from_secs(*timeout), || {
                    if wait_utils::http_check_ok(self.dbg, url) {
                        Probe::Ready(())
                    } else {
                        Probe::Retry(format!("{url} has not returned a success status"))
                    }
                })
            }

            // Honoured by service_utils, whose driver is async. Reported rather than waited on,
            // so that a caller learns immediately instead of after a timeout.
            WaitStrategy::WaitForGrpcHealthCheck(_, _) => Err(DockerError::from(
                "WaitForGrpcHealthCheck needs an async driver and is not supported by \
                 docker_utils. Use service_utils, or express the check as WaitUntilReady."
                    .to_string(),
            )),

            WaitStrategy::WaitUntilReady {
                probe,
                timeout_secs,
                retry_delay_ms,
            } => self.run_readiness_probe(
                container_id,
                host,
                port,
                *probe,
                Duration::from_secs(*timeout_secs),
                Duration::from_millis(*retry_delay_ms),
            ),
        }
    }

    /// Polls `check` until it reports ready, aborting as soon as the container dies.
    fn poll_until<F>(
        &self,
        container_id: &str,
        timeout: Duration,
        mut check: F,
    ) -> Result<(), DockerError>
    where
        F: FnMut() -> Probe<(), String>,
    {
        wait_utils::wait_until_ready(self.dbg, timeout, POLL_INTERVAL, || {
            match self.container_died(container_id) {
                Some(dead) => Probe::Fatal(dead),
                None => check(),
            }
        })
        .map_err(|e| DockerError::from(format!("container '{container_id}': {e}")))
    }

    /// Runs a caller-supplied readiness probe on a thread of its own.
    ///
    /// The probe is synchronous by contract and may build its own async runtime. It can only
    /// do so with no ambient runtime, and `setup_container` is routinely called from inside
    /// `#[tokio::test]`, where building one panics. Owning a thread here is what makes the
    /// contract hold for every caller instead of being each probe author's problem.
    ///
    /// Everything moved across is `Send`: a `ProbeFn` is a function pointer, `ProbeContext`
    /// owns its strings, and `DockerUtil` is `Copy`.
    fn run_readiness_probe(
        &self,
        container_id: &str,
        host: &str,
        port: u16,
        probe: ProbeFn,
        timeout: Duration,
        retry_delay: Duration,
    ) -> Result<(), DockerError> {
        let docker = *self;
        let id = container_id.to_string();
        let host = host.to_string();

        let handle = std::thread::spawn(move || {
            let mut attempt = 0u32;

            wait_utils::wait_until_ready(docker.dbg, timeout, retry_delay, || {
                attempt = attempt.saturating_add(1);

                match docker.container_died(&id) {
                    Some(dead) => Probe::Fatal(dead),
                    None => probe(&ProbeContext::new(id.clone(), host.clone(), port, attempt)),
                }
            })
        });

        match handle.join() {
            Ok(Ok(())) => Ok(()),
            Ok(Err(e)) => Err(DockerError::from(format!(
                "container '{container_id}': {e}"
            ))),
            Err(_) => Err(DockerError::from(format!(
                "container '{container_id}': the readiness probe panicked"
            ))),
        }
    }

    /// Reports the container as dead only on a definite answer.
    ///
    /// An `Err` means docker did not answer, which is not evidence the container died.
    /// Treating it as death would fail an otherwise healthy run on a transient hiccup.
    fn container_died(&self, container_id: &str) -> Option<String> {
        match self.check_running(container_id) {
            Ok(false) => Some(format!("container '{container_id}' stopped while waiting")),
            _ => None,
        }
    }

    /// Attaches the container's post-mortem to a wait failure.
    ///
    /// This has to happen here rather than in the caller: containers carry `--rm`, so Docker
    /// reaps them within seconds of the exit that explains the failure.
    fn explain_wait_failure(&self, container_id: &str, error: &str) -> DockerError {
        match self.diagnostics(container_id, WAIT_FAILURE_LOG_TAIL) {
            Ok(diagnostics) if diagnostics.looks_oom_killed() => DockerError::from(format!(
                "{error}\ncontainer was OOM-killed, raise the memory limit\n{diagnostics}"
            )),
            Ok(diagnostics) => DockerError::from(format!("{error}\n{diagnostics}")),
            Err(_) => DockerError::from(format!(
                "{error} (diagnostics unavailable: the container was already removed)"
            )),
        }
    }
}
