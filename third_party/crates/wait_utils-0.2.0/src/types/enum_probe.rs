/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The buildutils Authors and Contributors. All Rights Reserved.
 */

/// The outcome of one readiness attempt.
///
/// Three-way rather than `Result`, because "not yet" and "never" need different handling and
/// collapsing them costs the caller either correctness or time: retrying a permanent failure
/// burns the whole budget and then reports a timeout, which hides the real cause.
#[derive(Debug, Clone, Eq, PartialEq)]
pub enum Probe<T, E> {
    /// The thing is ready. Carries whatever the probe built, e.g. a connected client.
    Ready(T),
    /// Not ready yet, and worth another attempt.
    Retry(E),
    /// Will not become ready. Stop immediately.
    Fatal(E),
}
