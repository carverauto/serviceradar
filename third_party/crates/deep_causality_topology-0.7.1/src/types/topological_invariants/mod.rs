/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Topology-only invariants extracted from a `HodgeDecomposition<R>`.
//!
//! `TopologicalInvariants<R>` is the pure-topology product of Block B1a of
//! [`openspec/notes/3DCausalFluidDynamics.md`](../../../../openspec/notes/3DCausalFluidDynamics.md):
//! given a manifold and the Hodge–Helmholtz decomposition of some k-form
//! field on it, the invariants are the four Betti numbers `β_0..β_3` of the
//! underlying chain complex plus the three component L2 norms
//! `(‖α‖, ‖β‖, ‖h‖)` of the decomposition.
//!
//! This is exactly the subset of the original B1 design that belongs in the
//! topology crate. The physics quantities the original B1 conflated with
//! topology — vortex detection, helicity sign, integral/Taylor length scales —
//! are field-theoretic invariants of the velocity field, not properties of
//! the discretisation, and live in `deep_causality_physics` (as a separate
//! block in the revised 3D-fluid-dynamics design note).
//!
//! The Betti array is fixed-size `[usize; 4]` and zero-padded for grades
//! beyond the manifold's max dimension. This matches the 3D-fluid pipeline's
//! consumer expectation and keeps the type non-generic over ambient
//! dimension, which simplifies downstream consumers (rolling history,
//! SURD-input assembly) at the cost of carrying two zeros for 2D inputs.

use deep_causality_algebra::RealField;
mod display;
mod from_hodge_decomposition;
mod getters;
mod part_eq;

/// Pure-topology invariants of a Hodge–Helmholtz decomposition.
///
/// Constructed via `HodgeDecomposition::topological_invariants(&manifold)`.
/// Fields are private; read access is through the getters in `getters`.
#[derive(Debug, Clone)]
pub struct TopologicalInvariants<R: RealField> {
    betti_numbers: [usize; 4],
    exact_l2_norm: R,
    co_exact_l2_norm: R,
    harmonic_l2_norm: R,
}

impl<R: RealField> TopologicalInvariants<R> {
    /// Constructs a `TopologicalInvariants<R>` from prescribed Betti numbers and
    /// L2 norms.
    ///
    /// Callers constructing values directly (e.g. tests, future consumers) are
    /// responsible for supplying well-formed values. The
    /// `HodgeDecomposition::topological_invariants` constructor is the canonical
    /// path; it derives every field from the input decomposition and manifold.
    pub fn new(
        betti_numbers: [usize; 4],
        exact_l2_norm: R,
        co_exact_l2_norm: R,
        harmonic_l2_norm: R,
    ) -> Self {
        Self {
            betti_numbers,
            exact_l2_norm,
            co_exact_l2_norm,
            harmonic_l2_norm,
        }
    }
}
