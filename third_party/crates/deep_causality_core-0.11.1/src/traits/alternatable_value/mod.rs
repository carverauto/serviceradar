/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

/// Defines the value-channel alternation operation for a monadic effect system.
///
/// `alternate_value` replaces the `value` channel of an in-flight carrier with
/// a different one, preserving every other channel (state, context, error,
/// logs). It is the mid-chain mechanism by which a hypothetical or corrective
/// value can be threaded into a running causal chain.
///
/// It is the value-channel member of the symmetric
/// [`AlternatableValue`] / [`crate::AlternatableContext`] /
/// [`crate::AlternatableState`] family — counterfactual substitution on one channel. This is the
/// value-level substitution lens; Pearl's `do(...)` operator (graph surgery / variable isolation)
/// lives at the `deep_causality` Causaloid + hypergraph layer, where a graph is in scope.
///
/// # Contract
///
/// - **Error state**: If the upstream chain has already errored, the error
///   is propagated and the alternation is *not* applied. An alternation
///   cannot fix a previously broken chain.
/// - **State and context**: Preserved unchanged.
/// - **Log history**: Preserved, with one `!!ValueAlternation!!` entry
///   appended so the audit trail records the substitution.
pub trait AlternatableValue<V> {
    /// Replace the carried value with `new_value`, preserving the rest of
    /// the chain.
    fn alternate_value(self, new_value: V) -> Self;
}
