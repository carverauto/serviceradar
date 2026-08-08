/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! SU(2) gauge group - Weak isospin.
//!
//! The SU(2) group has three generators (W+, W-, Z before symmetry breaking).
//! It is non-abelian, so the field strength includes self-interaction: F = dA + A∧A.

use crate::traits::gauge_group::GaugeGroup;

/// SU(2) gauge group marker.
///
/// Represents the gauge symmetry of the weak isospin interaction.
///
/// # Properties
///
/// - **Lie algebra dimension**: 3 (three generators)
/// - **Abelian**: No (non-commutative)
/// - **Convention**: West Coast (+---) by default
///
/// # Physics
///
/// The SU(2) gauge symmetry corresponds to weak isospin rotations.
/// Before electroweak symmetry breaking, it gives rise to three gauge bosons.
/// After symmetry breaking (combined with U(1)), these become W+, W-, and Z.
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash)]
pub struct SU2;

impl GaugeGroup for SU2 {
    const LIE_ALGEBRA_DIM: usize = 3;
    const IS_ABELIAN: bool = false;

    fn name() -> &'static str {
        "SU(2)"
    }

    /// Returns the SU(2) structure constant ε_{abc}.
    fn structure_constant(a: usize, b: usize, c: usize) -> f64 {
        match (a, b, c) {
            // Permutations of 123 (mapped to 012)
            (0, 1, 2) => 1.0,
            (1, 2, 0) => 1.0,
            (2, 0, 1) => 1.0,

            // Anti-permutations
            (0, 2, 1) => -1.0,
            (2, 1, 0) => -1.0,
            (1, 0, 2) => -1.0,

            // All others are zero
            _ => 0.0,
        }
    }
}
