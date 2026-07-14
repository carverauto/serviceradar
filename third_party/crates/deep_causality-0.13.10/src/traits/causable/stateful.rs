/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Stateful counterpart to [`crate::MonadicCausable`].
//!
//! `StatefulMonadicCausable<I, O, S, C>` exposes an evaluation method that
//! threads user-defined `State` and `Context` through a causaloid without
//! collapsing them at the trait-method boundary. It coexists with
//! `MonadicCausable<I, O>` — the two traits are independent and a single
//! `Causaloid` value can satisfy both simultaneously, allowing either form of
//! evaluation depending on which method the caller invokes.
//!
//! Use the stateless `MonadicCausable<I, O>` when the causal chain does not
//! need to carry Markovian state or read-only context (`State = ()`,
//! `Context = ()`). Use this stateful trait when state, context, or both must
//! be threaded through the evaluation result.

use deep_causality_core::PropagatingProcess;

/// Stateful counterpart to [`crate::MonadicCausable`].
///
/// Evaluation threads `S` and `C` from the incoming process through the
/// causaloid's stored closure and returns a `PropagatingProcess<O, S, C>` whose
/// `state` and `context` reflect whatever the closure produced — never a
/// freshly defaulted `S` and never a discarded context.
///
/// To author a `Causaloid` intended for stateful evaluation, use the existing
/// [`crate::Causaloid::new_with_context`] constructor with a closure typed as
/// [`crate::StatefulContextualCausalFn`]. **Statefulness is a property of the
/// evaluation call (which trait method is invoked), not of the constructor.**
/// The same `Causaloid` value can be evaluated via
/// [`crate::MonadicCausable::evaluate`] (stateless, drops state) or via
/// [`StatefulMonadicCausable::evaluate_stateful`] (preserves state).
pub trait StatefulMonadicCausable<I, O, S, C> {
    /// Evaluate the causaloid in stateful form.
    ///
    /// # State and context threading
    ///
    /// The `state` and `context` carried by `incoming` are passed into the
    /// causaloid's stored closure. The closure's returned `state` and
    /// `context` are returned to the caller intact.
    ///
    /// When the underlying causaloid is a singleton built with the stateless
    /// `causal_fn` variant (i.e. via [`crate::Causaloid::new`]), the incoming
    /// `state` and `context` are passed through unchanged on the returned
    /// process.
    ///
    /// # Logs
    ///
    /// Logs are accumulated chronologically across all internal evaluation
    /// steps and returned on the resulting process.
    ///
    /// # Error short-circuit
    ///
    /// If the causaloid produces an error, the returned process carries
    /// `error: Some(...)`, the `state` carried by `incoming` at the moment of
    /// failure (not `S::default()`), and the logs accumulated up to and
    /// including the failing step.
    fn evaluate_stateful(
        &self,
        incoming: &PropagatingProcess<I, S, C>,
    ) -> PropagatingProcess<O, S, C>;
}
