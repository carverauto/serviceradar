/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use deep_causality_algebra::RealField;
use deep_causality_tensor::CausalTensor;

use crate::types::hodge_decomposition::HodgeDecomposition;

impl<R: RealField> HodgeDecomposition<R> {
    /// Returns a borrowed view of the exact component `α = d φ_α`.
    #[inline]
    pub fn exact(&self) -> &CausalTensor<R> {
        &self.exact
    }

    /// Returns a borrowed view of the co-exact component `β = δ ψ_β`.
    #[inline]
    pub fn co_exact(&self) -> &CausalTensor<R> {
        &self.co_exact
    }

    /// Returns a borrowed view of the harmonic component `h = ω − α − β`.
    #[inline]
    pub fn harmonic(&self) -> &CausalTensor<R> {
        &self.harmonic
    }

    /// Returns the grade `k` of the decomposed form.
    #[inline]
    pub fn grade(&self) -> usize {
        self.grade
    }
}
