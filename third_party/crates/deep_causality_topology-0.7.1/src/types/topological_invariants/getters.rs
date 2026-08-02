/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::types::topological_invariants::TopologicalInvariants;
use deep_causality_algebra::RealField;

impl<R: RealField> TopologicalInvariants<R> {
    /// Returns the four Betti numbers `[β_0, β_1, β_2, β_3]`.
    ///
    /// Grades beyond the manifold's `max_dim` are zero-padded.
    #[inline]
    pub fn betti_numbers(&self) -> [usize; 4] {
        self.betti_numbers
    }

    /// Returns the L2 norm of the exact component `α = d φ_α`.
    #[inline]
    pub fn exact_l2_norm(&self) -> R {
        self.exact_l2_norm
    }

    /// Returns the L2 norm of the co-exact component `β = δ ψ_β`.
    #[inline]
    pub fn co_exact_l2_norm(&self) -> R {
        self.co_exact_l2_norm
    }

    /// Returns the L2 norm of the harmonic component `h = ω − α − β`.
    #[inline]
    pub fn harmonic_l2_norm(&self) -> R {
        self.harmonic_l2_norm
    }
}
