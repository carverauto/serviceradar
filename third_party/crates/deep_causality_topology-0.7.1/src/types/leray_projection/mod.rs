/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Result carrier for the Leray projection (`Manifold::leray_project`).
//!
//! Holds the divergence-free projected 1-form `P(ω) = ω − dφ` together with
//! the grade-0 potential `φ` from the half-decomposition solve
//! (`Δ₀ φ = δω`, gauge-fixed by mean subtraction). The potential is what the
//! opt-in pressure-recovery diagnostic consumes downstream; this crate does
//! not interpret it.

use deep_causality_tensor::CausalTensor;

/// The result of a Leray projection: the divergence-free component of a
/// 1-form and the grade-0 potential whose gradient was removed.
#[derive(Debug, Clone, PartialEq)]
pub struct LerayProjection<R> {
    /// `P(ω) = ω − dφ` — divergence-free to the CG tolerance.
    projected: CausalTensor<R>,
    /// The gauge-fixed grade-0 potential `φ` with `Δ₀ φ = δω`.
    potential: CausalTensor<R>,
}

impl<R> LerayProjection<R> {
    /// Crate-internal constructor; only the projection solve builds values.
    pub(crate) fn new(projected: CausalTensor<R>, potential: CausalTensor<R>) -> Self {
        Self {
            projected,
            potential,
        }
    }

    /// The divergence-free projected 1-form.
    pub fn projected(&self) -> &CausalTensor<R> {
        &self.projected
    }

    /// The grade-0 potential of the removed gradient component.
    pub fn potential(&self) -> &CausalTensor<R> {
        &self.potential
    }

    /// Consume into `(projected, potential)`.
    pub fn into_parts(self) -> (CausalTensor<R>, CausalTensor<R>) {
        (self.projected, self.potential)
    }
}
