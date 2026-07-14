/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

/// Defines the state-channel alternation operation for a monadic effect
/// system.
///
/// `alternate_state` replaces the `state` channel of an in-flight carrier
/// with a different one, preserving every other channel (value, context,
/// error, logs). It is the carrier-level mechanism for forcing the process
/// into a different state without going through `bind`, useful for
/// simulator resets, regime changes, and test fixtures.
///
/// # Contract
///
/// - **Error state**: If the upstream chain has already errored, the error
///   is propagated and the alternation is *not* applied. An alternation
///   cannot fix a previously broken chain.
/// - **Value and context**: Preserved unchanged.
/// - **Log history**: Preserved, with one `!!StateAlternation!!` entry
///   appended so the audit trail records the substitution.
///
/// # Behaviour on `PropagatingEffect`
///
/// On the stateless alias [`crate::PropagatingEffect`] (`State = ()`),
/// `alternate_state(())` is well-typed but has no observable effect on
/// downstream computation; only the audit-log entry is appended. The
/// operation is meaningful on the stateful [`crate::PropagatingProcess`].
pub trait AlternatableState<S> {
    /// Replace the carried state with `new_state`, preserving the rest of
    /// the chain.
    fn alternate_state(self, new_state: S) -> Self;
}
