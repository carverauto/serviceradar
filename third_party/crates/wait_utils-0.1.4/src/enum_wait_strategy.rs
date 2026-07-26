/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The buildutils Authors and Contributors. All Rights Reserved.
 */

use std::fmt::{Display, Formatter};

/// Represents the strategy to wait for a container to reach a certain state.
///
/// This enum defines different strategies to be used when waiting for a container
/// to be ready or to achieve a certain condition. It can be used to specify
/// how a container's readiness should be checked before considering it fully started
/// and operational.
///
/// Variants:
///
/// - `NoWait`: Do not wait. This variant indicates that the container should be considered
///   ready immediately after it is started, without any delay or additional checks.
///
/// - `WaitForDuration(duration: u64)`: Wait for a fixed duration. This variant takes a `u64`
///   value representing the number of seconds to wait before considering the container ready.
///   This strategy is useful when a container is known to take a certain time to initialize.
///
/// - `WaitUntilConsoleOutputContains(expected_output: String, timeout: u64)`: Wait until the container's
///   console output contains a specific string or until a timeout occurs. This variant takes a `String`
///   representing the expected output to wait for and a `u64` representing the timeout in seconds.
///   This strategy is useful for containers that emit a specific log message or signal when they are ready.
///
/// - `WaitForHttpHealthCheck(url: String, timeout: u64)`: Wait until an HTTP request to the given URL
///   returns a 200 status code or until a timeout occurs. This variant takes a `String` representing the URL to
///   make the request to and a `u64` representing the timeout in seconds.
///   This strategy is useful for containers that expose an HTTP server and indicate their readiness
///   by returning a 200 status code.
///
/// - `WaitForGrpcHealthCheck(url: String, timeout: u64)`: Wait until a gRPC request to the given URL
///   returns a successful response or until a timeout occurs. This variant takes a `String` representing the URL to
///   make the request to and a `u64` representing the timeout in seconds.
///   This strategy is useful for containers that expose a gRPC server and indicate their readiness
///   by returning a successful response.
///
///
/// Note that the usage of these strategies depends on the specific requirements of the
/// container and the context in which it is being started.
///
#[derive(Debug, Default, Clone, Eq, PartialOrd, Ord, PartialEq, Hash)]
pub enum WaitStrategy {
    #[default]
    NoWait,
    WaitForDuration(u64),
    WaitUntilConsoleOutputContains(String, u64),
    WaitForHttpHealthCheck(String, u64),
    WaitForGrpcHealthCheck(String, u64),
}

impl Display for WaitStrategy {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
