/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::errors::topology_error::TopologyError;
use crate::traits::chain_complex::ChainComplex;
use crate::types::hodge_decomposition::HodgeDecomposition;
use crate::types::manifold::Manifold;
use crate::types::topological_invariants::TopologicalInvariants;
use deep_causality_algebra::RealField;

impl<R: RealField> HodgeDecomposition<R> {
    /// Extracts the pure-topology invariants of this decomposition on the given
    /// manifold.
    ///
    /// The four Betti numbers `[β_0, β_1, β_2, β_3]` are read from
    /// `K::betti_number(k)` for `k = 0..=3`. Grades beyond
    /// `manifold.complex().max_dim()` are zero-padded.
    ///
    /// The three component L2 norms `(‖α‖, ‖β‖, ‖h‖)` are computed directly from
    /// the decomposition components stored in `self`. They satisfy the Hodge
    /// orthogonality identity `‖α‖² + ‖β‖² + ‖h‖² = ‖α + β + h‖²` to the
    /// numerical tolerance of `Manifold::hodge_decompose` (see the H3 property
    /// tests for verification of this identity at `1e-6` across precision
    /// backends).
    ///
    /// # Errors
    /// Currently returns no error variants; the `Result` return type is
    /// reserved for future validation (e.g. dimension consistency between
    /// `self` and `manifold`) without an API break.
    pub fn topological_invariants<K>(
        &self,
        manifold: &Manifold<K, R>,
    ) -> Result<TopologicalInvariants<R>, TopologyError>
    where
        K: ChainComplex,
    {
        let complex = manifold.complex();
        let mut betti = [0usize; 4];
        for (k, slot) in betti.iter_mut().enumerate() {
            *slot = complex.betti_number(k);
        }

        let exact = l2_norm(self.exact().as_slice());
        let co_exact = l2_norm(self.co_exact().as_slice());
        let harmonic = l2_norm(self.harmonic().as_slice());

        Ok(TopologicalInvariants::new(betti, exact, co_exact, harmonic))
    }
}

#[inline]
fn l2_norm<R: RealField>(v: &[R]) -> R {
    v.iter()
        .copied()
        .map(|x| x * x)
        .fold(R::zero(), |a, b| a + b)
        .sqrt()
}
