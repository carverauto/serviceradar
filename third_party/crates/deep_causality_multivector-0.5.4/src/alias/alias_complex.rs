/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{ComplexMultiVector, Metric};
use deep_causality_num_complex::Complex64;

impl ComplexMultiVector {
    /// Cl_C(2): Complex Quaternions / Pauli Algebra over C
    /// Note: The Clifford factor L_C ~ Cl(0, 1) and L_H ~ Cl(0, 2) are negative definite.
    /// However, the canonical complex Pauli Algebra is often taken as Cl(2, 0).
    /// We retain Euclidean(2) here for the canonical Cl_C(2) ~ Cl(2, 0) definition.
    pub fn new_complex_pauli(data: Vec<Complex64>) -> Self {
        Self::new_complex_clifford_2(data)
    }

    /// Cl_C(2): Complex Quaternions / Pauli Algebra over C
    /// Note: The Clifford factor L_C ~ Cl(0, 1) and L_H ~ Cl(0, 2) are negative definite.
    /// However, the canonical complex Pauli Algebra is often taken as Cl(2, 0).
    /// We retain Euclidean(2) here for the canonical Cl_C(2) ~ Cl(2, 0) definition.
    pub fn new_complex_clifford_2(data: Vec<Complex64>) -> Self {
        Self::new(data, Metric::Euclidean(2)).unwrap()
    }

    /// Cl_C(4) (Full Multiplication Algebra of the Quaternions, M_H ~ Cl(0, 4)).
    /// This algebra hosts the Spin(4) ~ SU(2)_L * SU(2)_R symmetries of the Pati-Salam and LR Symmetric models.
    /// It is a key building block for the electroweak sector.
    pub fn new_quaternion_operator(data: Vec<Complex64>) -> Self {
        Self::new_complex_clifford_4(data)
    }

    /// Cl_C(4) (Full Multiplication Algebra of the Quaternions, M_H ~ Cl(0, 4)).
    /// This algebra hosts the Spin(4) ~ SU(2)_L * SU(2)_R symmetries of the Pati-Salam and LR Symmetric models.
    /// It is a key building block for the electroweak sector.
    pub fn new_complex_clifford_4(data: Vec<Complex64>) -> Self {
        // Metric is NonEuclidean(4) for M_H ~ Cl(0, 4).
        // Dimension is 4, size is 2^4 = 16 complex coefficients.
        Self::new(data, Metric::NonEuclidean(4)).unwrap()
    }

    /// Cl_C(6): The algebra acting on Octonions (via Left Multiplication), L_O ~ Cl(0, 6)
    /// Used for the initial decomposition in the paper (Spin(10) -> Pati-Salam).
    pub fn new_octonion_operator(data: Vec<Complex64>) -> Self {
        Self::new_complex_clifford_6(data)
    }
    /// Cl_C(6): The algebra acting on Octonions (via Left Multiplication), L_O ~ Cl(0, 6)
    /// Used for the initial decomposition in the paper (Spin(10) -> Pati-Salam).
    pub fn new_complex_clifford_6(data: Vec<Complex64>) -> Self {
        // Metric is NonEuclidean(6) to represent the generators e_i^2 = -1 (imaginary units).
        Self::new(data, Metric::NonEuclidean(6)).unwrap()
    }

    /// Cl_C(6): The algebra of the Dixon state space, A = C*H*O ~ Cl(0, 6)
    /// This is used to host the 64 complex components of the Standard Model generations.
    pub fn new_dixon_state_space(data: Vec<Complex64>) -> Self {
        Self::new_complex_clifford_6(data)
    }

    /// Cl_C(8): The Left Multiplication Algebra of the Dixon Algebra, L_A ~ Cl(0, 8)
    /// L_A = L_C * L_H * L_O ~ Cl(0, 1) * Cl(0, 2) * Cl(0, 6) ~ Cl(0, 8).
    /// This is used to host Spin(8) triality and the Cl(6) decomposition.
    pub fn new_dixon_algebra_left(data: Vec<Complex64>) -> Self {
        Self::new_complex_clifford_8(data)
    }

    /// Cl_C(8): The Left Multiplication Algebra of the Dixon Algebra, L_A ~ Cl(0, 8)
    /// L_A = L_C * L_H * L_O ~ Cl(0, 1) * Cl(0, 2) * Cl(0, 6) ~ Cl(0, 8).
    /// This is used to host Spin(8) triality and the Cl(6) decomposition.
    pub fn new_complex_clifford_8(data: Vec<Complex64>) -> Self {
        // Metric is NonEuclidean(8) for L_A ~ Cl(0, 8).
        Self::new(data, Metric::NonEuclidean(8)).unwrap()
    }

    /// Cl_C(10): The Grand Unified Algebra (Spin(10)) ~ L_A * R_H ~ Cl(0, 10)
    /// This is the full multiplication algebra of A = R*C*H*O.
    pub fn new_gut_algebra(data: Vec<Complex64>) -> Self {
        Self::new_complex_clifford_10(data)
    }

    /// Cl_C(10): The Grand Unified Algebra (Spin(10)) ~ L_A * R_H ~ Cl(0, 10)
    /// This is the full multiplication algebra of A = R*C*H*O.
    pub fn new_complex_clifford_10(data: Vec<Complex64>) -> Self {
        // Metric is NonEuclidean(10) for M_A ~ Cl(0, 10).
        Self::new(data, Metric::NonEuclidean(10)).unwrap()
    }
}
