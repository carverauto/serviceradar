/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2026" . The buildutils Authors and Contributors. All Rights Reserved.
 */

use std::fmt::{Display, Formatter};

/// What the driver knows about the thing being waited on, handed to the probe each attempt.
///
/// The address is a chicken and egg problem: the caller cannot connect until it knows the
/// port, and the driver cannot bind or publish until the caller has chosen one. The config is
/// what breaks it, by being the single place both sides read, and this context is how the
/// driver hands that agreed address on to the probe.
///
/// Passing it in is also what removes the need for the probe to capture anything, which is
/// what keeps [`WaitStrategy`](crate::WaitStrategy) a plain data enum that every driver can
/// carry and every derive still applies to.
///
/// `attempt` is the one field no caller can know, which is what lets a probe escalate to
/// [`Probe::Fatal`](crate::Probe::Fatal) without holding state of its own.
#[derive(Debug, Clone, Eq, PartialEq, Hash)]
pub struct ProbeContext {
    id: String,
    host: String,
    port: u16,
    attempt: u32,
}

impl ProbeContext {
    /// Create a new instance of the `ProbeContext` struct.
    ///
    /// # Arguments
    ///
    /// * `id` - The ID of the container or service being waited on.
    /// * `host` - The host the caller will connect to.
    /// * `port` - The port the caller will connect to.
    /// * `attempt` - Which attempt this is, counting from one.
    ///
    /// # Returns
    ///
    /// Returns a new `ProbeContext` instance.
    ///
    #[must_use]
    pub const fn new(id: String, host: String, port: u16, attempt: u32) -> Self {
        Self {
            id,
            host,
            port,
            attempt,
        }
    }

    /// The ID of the container or service being waited on.
    #[inline]
    #[must_use]
    pub fn id(&self) -> &str {
        &self.id
    }

    /// The host the caller will connect to.
    #[inline]
    #[must_use]
    pub fn host(&self) -> &str {
        &self.host
    }

    /// The port the caller will connect to.
    #[inline]
    #[must_use]
    pub const fn port(&self) -> u16 {
        self.port
    }

    /// Which attempt this is, counting from one.
    ///
    /// Lets a probe escalate to [`Probe::Fatal`](crate::Probe::Fatal) after a number of
    /// attempts without having to carry state of its own.
    #[inline]
    #[must_use]
    pub const fn attempt(&self) -> u32 {
        self.attempt
    }
}

impl Display for ProbeContext {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "id: {}, host: {}, port: {}, attempt: {}",
            self.id, self.host, self.port, self.attempt
        )
    }
}
