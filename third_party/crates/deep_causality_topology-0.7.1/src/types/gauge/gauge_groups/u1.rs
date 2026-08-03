/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! U(1) gauge group - Quantum Electrodynamics (electromagnetism).
//!
//! The U(1) group has a single generator (the photon).
//! It is abelian, so the field strength is simply F = dA.

use crate::traits::gauge_group::GaugeGroup;

/// U(1) gauge group marker.
///
/// Represents the gauge symmetry of Quantum Electrodynamics (QED).
///
/// # Properties
///
/// - **Lie algebra dimension**: 1 (one photon)
/// - **Abelian**: Yes (commutative)
/// - **Convention**: West Coast (+---) by default
///
/// # Physics
///
/// The U(1) gauge symmetry corresponds to invariance under local phase rotations:
/// ψ(x) → e^{iθ(x)} ψ(x)
///
/// This symmetry gives rise to the electromagnetic interaction mediated by the photon.
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash)]
pub struct U1;

impl GaugeGroup for U1 {
    const LIE_ALGEBRA_DIM: usize = 1;
    const IS_ABELIAN: bool = true;

    fn name() -> &'static str {
        "U(1)"
    }

    /// U(1) is represented as 1×1 complex phase.
    fn matrix_dim() -> usize {
        1
    }
    // Uses default West Coast metric (particle physics convention)
}
