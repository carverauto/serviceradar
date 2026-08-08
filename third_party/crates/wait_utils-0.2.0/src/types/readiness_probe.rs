/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2026" . The buildutils Authors and Contributors. All Rights Reserved.
 */

use std::fmt::Display;

use crate::Probe;

/// A caller-supplied readiness condition.
///
/// Every other [`WaitStrategy`](crate::WaitStrategy) variant is a fixed predicate this crate
/// implements, and none of them can express "the operation I am about to perform succeeds" --
/// the only predicate that is never wrong about readiness. A service that accepts connections
/// before it accepts writes passes every built-in gate and still fails the caller's first real
/// call.
///
/// # Why this is synchronous
///
/// A wait strategy blocks until the container is usable; a probe that returns before it knows
/// is not a probe. Strategies are applied from `setup_container`, which is synchronous, so an
/// async probe cannot be driven from there without either making the whole crate async or
/// calling `block_on` -- which panics when the caller already has a runtime.
///
/// A caller whose real check is async owns the flattening, because only the caller knows
/// whether a runtime already exists. `WaitForGrpcHealthCheck` is what happens otherwise: its
/// implementation is `async`, so it could never be applied from the sync path, and the variant
/// shipped as a stub that always errors.
///
/// # Example
///
/// ```rust
/// use wait_utils::{Probe, ReadinessProbe};
///
/// #[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
/// struct PortAccepts {
///     addr: String,
/// }
///
/// impl ReadinessProbe for PortAccepts {
///     type Error = String;
///
///     fn probe(&self) -> Probe<(), Self::Error> {
///         match std::net::TcpStream::connect(&self.addr) {
///             Ok(_) => Probe::Ready(()),
///             Err(e) => Probe::Retry(format!("{} not accepting yet: {e}", self.addr)),
///         }
///     }
/// }
/// ```
pub trait ReadinessProbe {
    /// Reported when the probe is not ready. `Display` because the wait loop logs it.
    type Error: Display;

    /// Run one attempt.
    ///
    /// Takes `&self` so a probe stays a question about the world rather than a stateful
    /// object, which is also what keeps [`WaitStrategy`](crate::WaitStrategy) `Clone`.
    ///
    /// Should not block materially longer than the caller's retry delay: the wait loop can
    /// only notice a timeout between attempts.
    fn probe(&self) -> Probe<(), Self::Error>;
}

/// Placeholder so [`WaitStrategy`](crate::WaitStrategy) has a concrete default type parameter.
///
/// Never constructed by the other variants. It exists only so that `WaitStrategy::NoWait` and
/// friends still need no turbofish once the enum became generic.
#[derive(Debug, Default, Clone, Copy, Eq, PartialOrd, Ord, PartialEq, Hash)]
pub struct NoProbe;

impl ReadinessProbe for NoProbe {
    type Error = &'static str;

    fn probe(&self) -> Probe<(), Self::Error> {
        // Unreachable through the public API: no variant carrying NoProbe exists. Fatal
        // rather than Ready so that a future refactor which does reach it fails loudly
        // instead of silently reporting every container ready.
        Probe::Fatal("NoProbe is a type-level placeholder and must never be used as a probe")
    }
}
