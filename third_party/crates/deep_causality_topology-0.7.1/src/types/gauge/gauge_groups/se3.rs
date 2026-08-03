/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! SE(3) Gauge Group - Rigid Body Motions.
//!
//! The SE(3) group has six generators (3 rotations + 3 translations).
//! It is the semidirect product of SO(3) and R^3.

use crate::traits::gauge_group::GaugeGroup;

/// SE(3) gauge group marker.
///
/// Represents the gauge symmetry of rigid body motions (Special Euclidean Group).
///
/// # Properties
///
/// - **Lie algebra dimension**: 6 (3 rotations + 3 translations)
/// - **Abelian**: No (non-commutative)
/// - **Representation**: 4x4 Homogeneous Matrices
///
/// # Physics
///
/// The SE(3) group describes rigid body kinematics and is fundamental in robotics
/// and classical mechanics. It consists of:
/// - 3 Rotations (J₁, J₂, J₃)
/// - 3 Translations (P₁, P₂, P₃)
///
/// The Lie algebra $\mathfrak{se}(3)$ has the commutation relations:
/// - $[J_i, J_j] = \epsilon_{ijk} J_k$
/// - $[J_i, P_j] = \epsilon_{ijk} P_k$
/// - $[P_i, P_j] = 0$
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash)]
pub struct SE3;

impl GaugeGroup for SE3 {
    const LIE_ALGEBRA_DIM: usize = 6;
    const IS_ABELIAN: bool = false;

    fn name() -> &'static str {
        "SE(3)"
    }

    /// SE(3) is represented using 4x4 homogeneous matrices.
    fn matrix_dim() -> usize {
        4
    }

    /// Returns the SE(3) structure constants f^{abc}.
    ///
    /// # Generator Ordering
    /// Indices 0-2: Rotations J₁, J₂, J₃
    /// Indices 3-5: Translations P₁, P₂, P₃
    fn structure_constant(a: usize, b: usize, c: usize) -> f64 {
        // Levi-Civita helper for indices 0,1,2
        let epsilon = |i: usize, j: usize, k: usize| -> f64 {
            match (i, j, k) {
                (0, 1, 2) | (1, 2, 0) | (2, 0, 1) => 1.0,
                (0, 2, 1) | (2, 1, 0) | (1, 0, 2) => -1.0,
                _ => 0.0,
            }
        };

        // Check which block: Rot-Rot, Rot-Trans, Trans-Trans
        let a_is_rotation = a < 3;
        let b_is_rotation = b < 3;
        let c_is_rotation = c < 3;

        match (a_is_rotation, b_is_rotation, c_is_rotation) {
            // [Jᵢ, Jⱼ] = εᵢⱼₖ Jₖ (Rotation-Rotation -> Rotation)
            (true, true, true) => epsilon(a, b, c),

            // [Jᵢ, Pⱼ] = εᵢⱼₖ Pₖ (Rotation-Translation -> Translation)
            // Need a < 3 (Rot), b >= 3 (Trans), c >= 3 (Trans)
            (true, false, false) if c >= 3 => epsilon(a, b - 3, c - 3),

            // [Pᵢ, Jⱼ] = -[Jⱼ, Pᵢ] = -εⱼᵢₖ Pₖ
            // Need a >= 3 (Trans), b < 3 (Rot), c >= 3 (Trans)
            (false, true, false) if c >= 3 => -epsilon(b, a - 3, c - 3),

            // [Pᵢ, Pⱼ] = 0 (Translations commute)
            (false, false, _) => 0.0,

            // All other combinations are zero
            _ => 0.0,
        }
    }
}
