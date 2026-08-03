/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Lorentz SO(3,1) gauge group - General Relativity.
//!
//! The Lorentz group has six generators (3 rotations + 3 boosts).
//! When used as a gauge group, it provides the frame bundle for spacetime.

use crate::traits::gauge_group::GaugeGroup;
use deep_causality_metric::Metric;

/// Lorentz SO(3,1) gauge group marker.
///
/// Represents the gauge symmetry of General Relativity (GR).
///
/// # Properties
///
/// - **Lie algebra dimension**: 6 (3 rotations + 3 boosts)
/// - **Abelian**: No (non-commutative)
/// - **Convention**: East Coast (-+++) by default (GR standard)
///
/// # Physics
///
/// The Lorentz group SO(3,1) describes spacetime symmetries:
/// - 3 spatial rotations (J₁, J₂, J₃)
/// - 3 Lorentz boosts (K₁, K₂, K₃)
///
/// In the gauge formulation of GR, the Lorentz group acts on the frame bundle,
/// with the connection (spin connection) measuring how frames rotate
/// as we move through spacetime.
///
/// # Metric Convention
///
/// GR traditionally uses the East Coast (MTW) convention:
/// η = diag(-1, +1, +1, +1)
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash)]
pub struct SO3_1;

impl GaugeGroup for SO3_1 {
    const LIE_ALGEBRA_DIM: usize = 6;
    const IS_ABELIAN: bool = false;

    fn name() -> &'static str {
        "SO(3,1)"
    }

    /// East Coast convention (-+++) for GR.
    fn default_metric() -> Metric {
        // East Coast: time is negative, space is positive
        // Metric::Generic { p, q, r } where p=positive, q=negative, r=degenerate
        // For East Coast (-+++): three +1 (space), one -1 (time)
        Metric::Generic { p: 3, q: 1, r: 0 }
    }

    /// SO(3,1) acts on 4D spacetime, so matrices are 4×4.
    fn matrix_dim() -> usize {
        4
    }

    /// Returns the SO(3,1) Lorentz algebra structure constants f^{abc}.
    ///
    /// # Generator Ordering
    /// Indices 0-2: Rotations J₁, J₂, J₃
    /// Indices 3-5: Boosts K₁, K₂, K₃
    ///
    /// # Commutation Relations
    /// ```text
    /// [Jᵢ, Jⱼ] = εᵢⱼₖ Jₖ      (rotations form SO(3))
    /// [Jᵢ, Kⱼ] = εᵢⱼₖ Kₖ      (boosts transform as vectors)
    /// [Kᵢ, Kⱼ] = -εᵢⱼₖ Jₖ     (boosts don't close on themselves)
    /// ```
    fn structure_constant(a: usize, b: usize, c: usize) -> f64 {
        // Levi-Civita helper for indices 0,1,2
        let epsilon = |i: usize, j: usize, k: usize| -> f64 {
            match (i, j, k) {
                (0, 1, 2) | (1, 2, 0) | (2, 0, 1) => 1.0,
                (0, 2, 1) | (2, 1, 0) | (1, 0, 2) => -1.0,
                _ => 0.0,
            }
        };

        // Check which block: J-J, J-K, K-K
        let a_is_rotation = a < 3;
        let b_is_rotation = b < 3;
        let c_is_rotation = c < 3;

        match (a_is_rotation, b_is_rotation, c_is_rotation) {
            // [Jᵢ, Jⱼ] = εᵢⱼₖ Jₖ (rotation-rotation → rotation)
            (true, true, true) => epsilon(a, b, c),

            // [Jᵢ, Kⱼ] = εᵢⱼₖ Kₖ (rotation-boost → boost)
            (true, false, false) if c >= 3 => epsilon(a, b - 3, c - 3),
            (false, true, false) if c >= 3 => -epsilon(a - 3, b, c - 3), // antisymmetry

            // [Kᵢ, Kⱼ] = -εᵢⱼₖ Jₖ (boost-boost → rotation with minus sign)
            (false, false, true) if a >= 3 && b >= 3 => -epsilon(a - 3, b - 3, c),

            _ => 0.0,
        }
    }
}
