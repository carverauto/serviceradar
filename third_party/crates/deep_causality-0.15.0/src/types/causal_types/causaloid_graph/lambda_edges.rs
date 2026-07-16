/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Per-edge Λ decoration slots for a causal graph.
//!
//! Λ is Hardy's connection data (Hardy, *Probability Theories with Dynamic Causal Structure*,
//! arXiv:gr-qc/0509120, p. 4: the Λ matrices "break the symmetry between elementary regions"):
//! an optional transform attached to one identified edge, applied to the value flowing along that
//! edge *before* the commutative merge `∇` at a reconvergent join — `join = ∇ ∘ (Λ₁ ⊗ Λ₂)`.
//! Connection asymmetry lives on the edge; the fuse stays commutative; the element never sees an
//! order. Machine-checked model: `core.causaloid.inversion` in
//! `lean/DeepCausalityFormal/Core/Causaloid.lean` (the Λ-edge map is modeled as the keyed function
//! `Nat → Nat → Option Λ`, intrinsically enumeration-order-free).
//!
//! Slots are keyed by **intrinsic edge identity** — the `(source, target)` node-index pair — and
//! never by enumeration or insertion order. An edge with no slot behaves as the identity Λ, so an
//! undecorated graph evaluates exactly as before. The decorated join itself is applied by the
//! Stage-4 graph algebra (`core.causaloid.graph_fold_order_invariant`); this type is the storage
//! and lookup substrate.

use std::collections::BTreeMap;

/// A per-edge Λ transform on the value channel: the arrow applied to the value flowing along one
/// identified edge before the join merge. A plain `fn` pointer, consistent with the crate's
/// `CausalFn` family (no `dyn`, no stored closures).
pub type EdgeLambdaFn<V> = fn(V) -> V;

/// Identity-keyed store of per-edge Λ decoration slots for one causal graph.
///
/// Keys are `(source, target)` node-index pairs — the intrinsic identity of a directed edge in
/// the graph — so which Λ applies to which input of a join is independent of any enumeration
/// order. Absent key = identity Λ (see [`LambdaEdges::apply`]).
pub struct LambdaEdges<V> {
    slots: BTreeMap<(usize, usize), EdgeLambdaFn<V>>,
}

impl<V> LambdaEdges<V> {
    /// Creates an empty decoration store: every edge is the identity Λ.
    pub fn new() -> Self {
        Self {
            slots: BTreeMap::new(),
        }
    }

    /// Sets the Λ slot for the edge `source -> target`, returning the previously stored Λ if the
    /// slot was already decorated.
    pub fn insert(
        &mut self,
        source: usize,
        target: usize,
        lambda: EdgeLambdaFn<V>,
    ) -> Option<EdgeLambdaFn<V>> {
        self.slots.insert((source, target), lambda)
    }

    /// Builder form of [`LambdaEdges::insert`].
    pub fn with_lambda(mut self, source: usize, target: usize, lambda: EdgeLambdaFn<V>) -> Self {
        self.slots.insert((source, target), lambda);
        self
    }

    /// Looks up the Λ slot of the edge `source -> target` by its intrinsic identity.
    /// `None` means the edge is undecorated (identity Λ).
    pub fn get(&self, source: usize, target: usize) -> Option<EdgeLambdaFn<V>> {
        self.slots.get(&(source, target)).copied()
    }

    /// Applies the edge's Λ to a value: the stored transform if the edge is decorated, the
    /// identity otherwise — the "undecorated edge behaves as the identity Λ" contract.
    pub fn apply(&self, source: usize, target: usize, value: V) -> V {
        match self.get(source, target) {
            Some(lambda) => lambda(value),
            None => value,
        }
    }

    /// Number of decorated edges.
    pub fn len(&self) -> usize {
        self.slots.len()
    }

    /// True when no edge is decorated (the whole graph is identity-Λ).
    pub fn is_empty(&self) -> bool {
        self.slots.is_empty()
    }
}

impl<V> Default for LambdaEdges<V> {
    fn default() -> Self {
        Self::new()
    }
}

// Manual impl: `fn` pointers are `Copy` for every `V`, so no `V: Clone` bound is needed (a derive
// would add one spuriously).
impl<V> Clone for LambdaEdges<V> {
    fn clone(&self) -> Self {
        Self {
            slots: self.slots.clone(),
        }
    }
}

impl<V> std::fmt::Debug for LambdaEdges<V> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LambdaEdges")
            .field("decorated_edges", &self.slots.keys().collect::<Vec<_>>())
            .finish()
    }
}
