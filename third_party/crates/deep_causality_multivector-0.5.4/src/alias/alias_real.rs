/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{Metric, RealMultiVector};

// Generic Algebras
impl RealMultiVector {
    /// Cl(N, 0): Generic N-dimensional Euclidean algebra.
    /// All basis vectors square to +1.
    pub fn new_euclidean(data: Vec<f64>, dim: usize) -> Self {
        Self::new(data, Metric::Euclidean(dim)).unwrap()
    }
}

// Division Algebras (Standard Math)
impl RealMultiVector {
    /// Cl(0, 1): Isomorphic to Complex Numbers C
    /// Basis: {1, e1} where e1^2 = -1 (acts as i)
    pub fn new_complex_number(real: f64, imag: f64) -> Self {
        let data = vec![real, imag];
        Self::new(data, Metric::NonEuclidean(1)).unwrap()
    }

    /// Cl(1, 0): Isomorphic to Split-Complex (Hyperbolic) Numbers
    /// Basis: {1, e1} where e1^2 = +1 (acts as j)
    pub fn new_split_complex(a: f64, b: f64) -> Self {
        let data = vec![a, b];
        Self::new(data, Metric::Euclidean(1)).unwrap()
    }

    /// Cl(0, 2): Isomorphic to Quaternions H
    /// Basis: {1, e1, e2, e12}. e1^2 = e2^2 = -1.
    pub fn new_quaternion(w: f64, x: f64, y: f64, z: f64) -> Self {
        let data = vec![w, x, y, z];
        Self::new(data, Metric::NonEuclidean(2)).unwrap()
    }

    /// Cl(2, 0): Isomorphic to Split-Quaternions (Coquaternions) or M(2,R)
    /// Basis: {1, e1, e2, e12} where e1^2 = 1, e2^2 = 1.
    ///
    /// This algebra is often used in representing 2D isometries.
    pub fn new_split_quaternion(a: f64, b: f64, c: f64, d: f64) -> Self {
        let data = vec![a, b, c, d];
        // 2 dimensions, 4 coefficients for scalar, v1, v2, bivector
        Self::new(data, Metric::Euclidean(2)).unwrap()
    }
}

// The Physics Algebras (Spacetime)

impl RealMultiVector {
    /// Cl(3, 0): Algebra of Physical Space (APS) / Pauli Algebra
    /// Used for non-relativistic quantum mechanics (Pauli Matrices).
    pub fn new_aps_vector(data: Vec<f64>) -> Self {
        // Dimension 3, Euclidean Metric (+ + +)
        Self::new(data, Metric::Euclidean(3)).unwrap()
    }

    /// Cl(1, 3): Space-Time Algebra (STA) / Dirac Algebra
    /// Physics Convention: Time-like vector is positive. Metric: (+ - - -)
    /// This is a specialized case of Metric::Generic { p: 1, q: 3, r: 0 }.
    pub fn new_spacetime_algebra_1_3(data: Vec<f64>) -> Self {
        // Dimension 4, Minkowski Metric (+ - - -)
        Self::new(data, Metric::Minkowski(4)).unwrap()
    }

    /// Cl(3, 1): Spacetime Algebra (STA) / Dirac Algebra
    /// Mathematics/GR Convention: Space-like vectors are positive. Metric: (- + + +)
    /// This is a specialized case of Metric::Generic { p: 3, q: 1, r: 0 }.
    pub fn new_spacetime_algebra_3_1(data: Vec<f64>) -> Self {
        // The Minkowski definition is a special case that handles this:
        // We will use Custom for clarity since Minkowski is hardcoded to (+---).

        // Custom Metric: 4 dimensions. e0^2=-1, e1^2=+1, e2^2=+1, e3^2=+1.
        // neg_mask: bit 0 (e0) = 1.
        Self::new(
            data,
            Metric::Custom {
                dim: 4,
                neg_mask: 1,
                zero_mask: 0,
            },
        )
        .unwrap()
    }

    /// Cl(4, 1): Conformal Geometric Algebra (CGA)
    /// Used for computer graphics and advanced robotics.
    /// 5 Dimensions. Metric (+ + + + -).
    ///
    /// Basis: e1, e2, e3, e+ (e4), e- (e5).
    /// e5^2 = -1.
    pub fn new_cga_vector(data: Vec<f64>) -> Self {
        // Metric (+ + + + -) = Generic { p: 4, q: 1, r: 0 }
        Self::new(data, Metric::Generic { p: 4, q: 1, r: 0 }).unwrap()
    }
}
