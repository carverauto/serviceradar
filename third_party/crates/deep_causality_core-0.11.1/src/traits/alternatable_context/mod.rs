/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

/// Defines the context-channel alternation operation for a monadic effect
/// system.
///
/// `alternate_context` replaces the `context` channel of an in-flight carrier
/// with a different one, preserving every other channel (value, state, error,
/// logs). It is the carrier-level expression of the *Contextual Alternation*
/// pattern: re-evaluate the same causal law against a different world by
/// swapping the carried context mid-chain instead of building a separate
/// pipeline.
///
/// # Contract
///
/// - **Error state**: If the upstream chain has already errored, the error
///   is propagated and the alternation is *not* applied. An alternation
///   cannot fix a previously broken chain.
/// - **Value and state**: Preserved unchanged.
/// - **Log history**: Preserved, with one `!!ContextAlternation!!` entry
///   appended so the audit trail records the substitution.
///
/// # Behaviour on `PropagatingEffect`
///
/// On the stateless alias [`crate::PropagatingEffect`] (`Context = ()`),
/// `alternate_context(())` is well-typed but has no observable effect on
/// downstream computation; only the audit-log entry is appended. The
/// operation is meaningful on the stateful [`crate::PropagatingProcess`].
pub trait AlternatableContext<C> {
    /// Replace the carried context with `new_context`, preserving the rest
    /// of the chain.
    fn alternate_context(self, new_context: C) -> Self;
}
