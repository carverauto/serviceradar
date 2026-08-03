/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! SU(2)×U(1) gauge group - Electroweak unification.
//!
//! The electroweak group combines weak isospin SU(2) and weak hypercharge U(1).
//! It has four generators (three from SU(2) + one from U(1)).

use crate::traits::gauge_group::GaugeGroup;

/// Electroweak SU(2)×U(1) gauge group marker.
///
/// Represents the unified electroweak gauge symmetry.
///
/// # Properties
///
/// - **Lie algebra dimension**: 4 (3 from SU(2) + 1 from U(1))
/// - **Abelian**: No (SU(2) factor is non-abelian)
/// - **Convention**: West Coast (+---) by default
///
/// # Physics
///
/// The electroweak theory unifies:
/// - Weak isospin SU(2)_L (left-handed fermions)
/// - Weak hypercharge U(1)_Y
///
/// Before symmetry breaking: 4 massless gauge bosons.
/// After Higgs mechanism: photon γ (massless), W+, W-, Z (massive).
///
/// # Weinberg Angle
///
/// The mixing between SU(2) and U(1) is characterized by the Weinberg angle θ_W ≈ 28.7°.
#[allow(non_camel_case_types)]
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash)]
pub struct SU2_U1;

impl GaugeGroup for SU2_U1 {
    const LIE_ALGEBRA_DIM: usize = 4; // 3 + 1
    const IS_ABELIAN: bool = false;

    fn name() -> &'static str {
        "SU(2)×U(1)"
    }

    fn matrix_dim() -> usize {
        // SU(2) is 2×2 and U(1) is 1×1 → total 3×3 block-diagonal
        3
    }
}
