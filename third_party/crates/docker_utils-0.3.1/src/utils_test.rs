/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The buildutils Authors and Contributors. All Rights Reserved.
 */

//! Pure helpers behind the Docker commands this crate runs.
//!
//! They are public so that the test suite under `tests/` can exercise them directly. Each
//! one is a plain function over its inputs and runs no Docker command of its own.

use crate::DockerError;

/// Builds the full argument list for `docker run`.
///
/// Kept separate from the command that runs it so that the argument construction,
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
pub fn build_run_args(
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

/// Builds a `docker ps` name filter that matches `container_id` and nothing else.
///
/// Docker matches the name filter as a regular expression anywhere within the name, so an
/// unanchored filter for `nginx-80` also matches `nginx-8080` and would report the wrong
/// container as running.
pub fn exact_name_filter(container_id: &str) -> String {
    // A dot is the only regular expression metacharacter Docker permits in a container name.
    format!("--filter=name=^{}$", container_id.replace('.', "\\."))
}

/// Extracts the port from a container ID of the form `<name>-<port>`.
///
/// Returns an error rather than panicking, because container IDs reach the public API
/// straight from the caller and need not carry a port suffix at all.
pub fn container_port_from_id(container_id: &str) -> Result<u16, DockerError> {
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
pub fn image_tag(image: &str) -> Option<&str> {
    let image = image.trim();
    let last_colon = image.rfind(':')?;

    if image[last_colon..].contains('/') {
        // The colon belongs to the registry host, so the reference carries no tag.
        return None;
    }

    Some(&image[last_colon + 1..])
}
