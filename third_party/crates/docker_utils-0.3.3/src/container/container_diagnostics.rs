/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The buildutils Authors and Contributors. All Rights Reserved.
 */

use std::fmt::{Display, Formatter};

/// A container's post-mortem: why it is not doing what the caller expected.
///
/// Returned as data rather than printed, so a test can assert on it
/// (`assert!(!diag.oom_killed())`) and a caller using `tracing` is not forced to accept
/// `println!`. Use the [`Display`] impl for the common "dump everything" case.
#[derive(Debug, Clone, Eq, PartialEq, Hash)]
pub struct ContainerDiagnostics {
    status: String,
    running: bool,
    restart_count: u32,
    oom_killed: bool,
    exit_code: i32,
    started_at: String,
    finished_at: String,
    logs: Option<String>,
}

impl ContainerDiagnostics {
    /// Create a new instance of the `ContainerDiagnostics` struct.
    ///
    /// # Arguments
    ///
    /// * `status` - Docker's own state word.
    /// * `running` - Whether the container is running.
    /// * `restart_count` - How many times the container was restarted.
    /// * `oom_killed` - Whether the kernel OOM killer stopped the container.
    /// * `exit_code` - The process exit code.
    /// * `started_at` - When the container started.
    /// * `finished_at` - When the container finished.
    /// * `logs` - The captured log tail, if it could be read.
    ///
    /// # Returns
    ///
    /// Returns a new `ContainerDiagnostics` instance.
    ///
    #[allow(clippy::too_many_arguments)]
    #[must_use]
    pub const fn new(
        status: String,
        running: bool,
        restart_count: u32,
        oom_killed: bool,
        exit_code: i32,
        started_at: String,
        finished_at: String,
        logs: Option<String>,
    ) -> Self {
        Self {
            status,
            running,
            restart_count,
            oom_killed,
            exit_code,
            started_at,
            finished_at,
            logs,
        }
    }
}

impl ContainerDiagnostics {
    /// Docker's own state word: `running`, `exited`, `removing`, ...
    #[inline]
    #[must_use]
    pub fn status(&self) -> &str {
        &self.status
    }

    #[inline]
    #[must_use]
    pub const fn running(&self) -> bool {
        self.running
    }

    /// How many times the container was restarted.
    ///
    /// A non-zero count means any connection the caller held was severed, which is otherwise
    /// indistinguishable from a network fault.
    #[inline]
    #[must_use]
    pub const fn restart_count(&self) -> u32 {
        self.restart_count
    }

    /// Whether the kernel OOM killer stopped this container.
    ///
    /// The single most valuable field here. An OOM presents to a client as a connection error
    /// with no server-side explanation, because the server did not get to write one.
    #[inline]
    #[must_use]
    pub const fn oom_killed(&self) -> bool {
        self.oom_killed
    }

    /// Process exit code.
    ///
    /// `137` is `128 + SIGKILL`, which together with [`oom_killed`](Self::oom_killed) confirms
    /// an out-of-memory kill rather than an orderly shutdown.
    #[inline]
    #[must_use]
    pub const fn exit_code(&self) -> i32 {
        self.exit_code
    }

    #[inline]
    #[must_use]
    pub fn started_at(&self) -> &str {
        &self.started_at
    }

    #[inline]
    #[must_use]
    pub fn finished_at(&self) -> &str {
        &self.finished_at
    }

    /// Captured log tail, or `None` when docker could not produce it, almost always because
    /// the container no longer exists.
    #[inline]
    #[must_use]
    pub fn logs(&self) -> Option<&str> {
        self.logs.as_deref()
    }

    /// Whether this looks like an out-of-memory kill.
    ///
    /// Both signals are checked because either alone is ambiguous: `OOMKilled` has been
    /// unreliable on some storage and runtime combinations, and `137` is also what a plain
    /// `docker kill` produces.
    #[inline]
    #[must_use]
    pub const fn looks_oom_killed(&self) -> bool {
        self.oom_killed || self.exit_code == 137
    }
}

impl Display for ContainerDiagnostics {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        writeln!(
            f,
            "status={} running={} restarts={} oom={} exit={} started={} finished={}",
            self.status,
            self.running,
            self.restart_count,
            self.oom_killed,
            self.exit_code,
            self.started_at,
            self.finished_at,
        )?;

        match &self.logs {
            Some(logs) => write!(f, "{logs}"),
            None => write!(f, "(logs unavailable: the container no longer exists)"),
        }
    }
}
