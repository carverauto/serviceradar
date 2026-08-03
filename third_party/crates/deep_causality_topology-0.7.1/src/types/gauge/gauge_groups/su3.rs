/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! SU(3) gauge group - Quantum Chromodynamics (strong force).
//!
//! The SU(3) group has eight generators (eight gluons).
//! It is non-abelian, so gluons interact with each other.

use crate::traits::gauge_group::GaugeGroup;

/// SU(3) gauge group marker.
///
/// Represents the gauge symmetry of Quantum Chromodynamics (QCD).
///
/// # Properties
///
/// - **Lie algebra dimension**: 8 (eight gluons)
/// - **Abelian**: No (non-commutative, gluon self-interaction)
/// - **Convention**: West Coast (+---) by default
///
/// # Physics
///
/// The SU(3) gauge symmetry corresponds to color charge rotations.
/// Quarks carry one of three colors (red, green, blue).
/// The eight gluons mediate the strong force and carry color charge themselves.
///
/// # Gell-Mann Matrices
///
/// The eight generators are represented by the Gell-Mann matrices λ₁...λ₈.
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash)]
pub struct SU3;

impl GaugeGroup for SU3 {
    const LIE_ALGEBRA_DIM: usize = 8;
    const IS_ABELIAN: bool = false;

    fn name() -> &'static str {
        "SU(3)"
    }
}
