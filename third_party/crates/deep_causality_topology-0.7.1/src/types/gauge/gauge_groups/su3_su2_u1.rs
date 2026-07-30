/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! SU(3)×SU(2)×U(1) gauge group - Standard Model.
//!
//! The Standard Model group combines all three gauge interactions.
//! It has 12 generators (8 from SU(3) + 3 from SU(2) + 1 from U(1)).

use crate::traits::gauge_group::GaugeGroup;

/// Standard Model SU(3)×SU(2)×U(1) gauge group marker.
///
/// Represents the full Standard Model gauge symmetry.
///
/// # Properties
///
/// - **Lie algebra dimension**: 12 (8 + 3 + 1)
/// - **Abelian**: No (SU(3) and SU(2) factors are non-abelian)
/// - **Convention**: West Coast (+---) by default
///
/// # Physics
///
/// The Standard Model combines:
/// - SU(3)_C: Strong force (8 gluons)
/// - SU(2)_L: Weak isospin (3 weak bosons before mixing)
/// - U(1)_Y: Weak hypercharge (1 boson before mixing)
///
/// Total: 12 gauge bosons → 8 gluons + W+ + W- + Z + γ
///
/// # Note
///
/// The Standard Model does NOT include gravity.
/// For gravity, use the Lorentz gauge group separately.
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash)]
#[allow(non_camel_case_types)]
pub struct SU3_SU2_U1;

impl GaugeGroup for SU3_SU2_U1 {
    const LIE_ALGEBRA_DIM: usize = 12; // 8 + 3 + 1
    const IS_ABELIAN: bool = false;

    fn name() -> &'static str {
        "SU(3)×SU(2)×U(1)"
    }

    fn matrix_dim() -> usize {
        // SU(3) (3×3), SU(2) (2×2) and U(1) (1×1) block-diagonal → total 6×6
        6
    }
}
