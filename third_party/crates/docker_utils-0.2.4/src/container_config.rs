/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The buildutils Authors and Contributors. All Rights Reserved.
 */

use std::fmt::Display;
use wait_utils::WaitStrategy;
// https://github.com/elastio/bon
use bon::Builder;

/// Create a new instance of the `ContainerConfig` struct with the given parameters.
///
/// Examples
///
/// Creating a new configuration using the derived builder:
/// ```rust
///  use docker_utils::*;
///
///     let config = ContainerConfig::builder()
///         .name("test_container")
///         .image("test_image")
///         .tag("latest")
///         .url("0.0.0.0")
///         .connection_port(8080)
///         .reuse_container(true)
///         .keep_configuration(true)
///         .wait_strategy(WaitStrategy::NoWait)
///         .build();
/// ```
///
#[derive(Builder, Debug, Default, Clone, Eq, PartialOrd, Ord, PartialEq, Hash)]
pub struct ContainerConfig<'l> {
    name: &'l str,
    image: &'l str,
    tag: &'l str,
    url: &'l str,
    connection_port: u16,
    reuse_container: bool,
    keep_configuration: bool,
    additional_ports: Option<&'l [u16]>,
    additional_env_vars: Option<&'l [&'l str]>,
    platform: Option<&'l str>,
    wait_strategy: WaitStrategy,
}

impl<'l> ContainerConfig<'l> {
    /// Create a new instance of the `ContainerConfig` struct with the given parameters.
    ///
    /// # Arguments
    ///
    /// * `name` - The name of the container.
    /// * `image` - The image to use for the container.
    /// * `tag` - The tag of the image.
    /// * `url` - The default URL of the container. Usually 0.0.0.0
    /// * `connection_port` - The port number for the main connection i.e. 80 for a webserver.
    /// * `additional_ports` - An optional array of additional ports to publish.
    /// * `platform` - An optional platform string in case the container image is not multi-arch.
    /// * `reuse_container` - A boolean flag indicating whether to reuse an existing container if found.
    /// * `keep_configuration` -  A boolean flag indication whether to keep the configuration upon
    ///    every environment setup. If set to true, the same configuration will be used across all
    ///    environment setups. If false, each setup will re-create all tables and import data.,
    /// * `wait_strategy` - The wait strategy to use for the container.
    ///
    /// Examples
    ///
    /// Creating a new configuration using the constructor:
    /// ```rust
    /// use docker_utils::*;
    ///
    ///     let config =  ContainerConfig::new(
    ///         "test_container",
    ///         "test_image",
    ///         "latest",
    ///         "0.0.0.0",
    ///         8080,
    ///         Some(&[8081, 8082]),
    ///         Some(&["ENV_VAR=VALUE", "DEBUG=true"]),
    ///         Some("linux/amd64"),
    ///         true,
    ///         false,
    ///         WaitStrategy::default(), // NoWait is the default wait strategy
    ///     );
    /// ```
    ///
    /// # Returns
    ///
    /// Returns a new instance of the `ContainerConfig` struct.
    ///
    #[allow(clippy::too_many_arguments)]
    pub const fn new(
        name: &'l str,
        image: &'l str,
        tag: &'l str,
        url: &'l str,
        connection_port: u16,
        additional_ports: Option<&'l [u16]>,
        additional_env_vars: Option<&'l [&'l str]>,
        platform: Option<&'l str>,
        reuse_container: bool,
        keep_configuration: bool,
        wait_strategy: WaitStrategy,
    ) -> Self {
        Self {
            name,
            image,
            tag,
            url,
            connection_port,
            reuse_container,
            keep_configuration,
            additional_ports,
            additional_env_vars,
            platform,
            wait_strategy,
        }
    }
}

impl<'l> ContainerConfig<'l> {
    #[inline]
    pub const fn name(&self) -> &'l str {
        self.name
    }
    #[inline]
    pub fn container_image(&self) -> String {
        format!("{}:{}", self.image, self.tag)
    }
    #[inline]
    pub fn container_name(&self) -> String {
        format!("{}-{}", self.name, self.connection_port)
    }
    #[inline]
    pub const fn url(&self) -> &'l str {
        self.url
    }
    #[inline]
    pub const fn connection_port(&self) -> u16 {
        self.connection_port
    }
    #[inline]
    pub const fn additional_ports(&self) -> Option<&'l [u16]> {
        self.additional_ports
    }
    #[inline]
    pub const fn additional_env_vars(&self) -> Option<&'l [&'l str]> {
        self.additional_env_vars
    }
    #[inline]
    pub const fn platform(&self) -> Option<&'l str> {
        self.platform
    }
    #[inline]
    pub const fn reuse_container(&self) -> bool {
        self.reuse_container
    }
    #[inline]
    pub const fn keep_configuration(&self) -> bool {
        self.keep_configuration
    }
    #[inline]
    pub const fn wait_strategy(&self) -> &WaitStrategy {
        &self.wait_strategy
    }
    #[inline]
    pub const fn image(&self) -> &'l str {
        self.image
    }
    #[inline]
    pub const fn tag(&self) -> &'l str {
        self.tag
    }
}

impl Display for ContainerConfig<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "name: {}, image: {}:{}, url: {} connection_port: {}, additional_ports: {:?}, \
            additional_env_vars: {:?}, platform: {:?},  reuse_container: {}, keep_configuration: {}, wait_strategy: {}",
            self.name,
            self.image,
            self.tag,
            self.url,
            self.connection_port,
            self.additional_ports,
            self.additional_env_vars,
            self.platform,
            self.reuse_container,
            self.keep_configuration,
            self.wait_strategy,
        )
    }
}
