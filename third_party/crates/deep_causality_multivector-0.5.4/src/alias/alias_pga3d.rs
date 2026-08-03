/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

// 3D Projective Geometric Algebra
// Signature: R(3, 0, 1) -> 3 Euclidean, 0 Negative, 1 Zero

use crate::{Metric, PGA3DMultiVector};

impl PGA3DMultiVector {
    /// Creates a point in 3D Projective Geometric Algebra (PGA).
    ///
    /// The point $\mathbf{P}=(x, y, z, w)$ is represented as a tri-vector (dual basis).
    ///
    /// $$\mathbf{P} = x \mathbf{e}_{032} + y \mathbf{e}_{013} + z \mathbf{e}_{021} + w \mathbf{e}_{123}$$
    ///
    /// For a homogeneous point at $(x, y, z)$ (i.e., $w=1$), the internal data mapping is:
    ///
    /// | Component | Mathematical Blade | Canonical Blade (Index) | Coefficient |
    /// | :--- | :--- | :--- | :--- |
    /// | $w$ | $\mathbf{e}_{123}$ | $\mathbf{e}_{123}$ (Index 14) | $1.0$ |
    /// | $x$ | $\mathbf{e}_{032}$ | $-\mathbf{e}_{023}$ (Index 13) | $-x$ |
    /// | $y$ | $\mathbf{e}_{013}$ | $\mathbf{e}_{013}$ (Index 11) | $y$ |
    /// | $z$ | $\mathbf{e}_{021}$ | $-\mathbf{e}_{012}$ (Index 7) | $-z$ |
    ///
    /// *Note: The signs for $x$ and $z$ are flipped to align $\mathbf{e}_{032}$ and $\mathbf{e}_{021}$
    /// with the canonical basis ordering assumed by the multivector indices.*
    pub fn new_point(x: f64, y: f64, z: f64) -> Self {
        let mut data = vec![0.0; 16];

        // w * e123 (Index 14)
        data[14] = 1.0;

        // x * e032 -> x * (-e023) -> -x (Index 13)
        data[13] = -x;

        // y * e013 -> y (Index 11)
        data[11] = y;

        // z * e021 -> z * (-e012) -> -z (Index 7)
        data[7] = -z;

        Self::new(data, Metric::PGA(4)).unwrap()
    }

    /// Creates a translator (motor) in 3D PGA.
    ///
    /// A translator $T$ moves geometry by a vector $d = (x, y, z)$.
    /// $$ T = 1 - \frac{1}{2} (x e_{01} + y e_{02} + z e_{03}) $$
    ///
    /// Indices:
    /// * Scalar (0): 1.0
    /// * e01 (3): -x/2
    /// * e02 (5): -y/2
    /// * e03 (9): -z/2
    pub fn translator(x: f64, y: f64, z: f64) -> Self {
        let mut data = vec![0.0; 16];

        // Scalar part = 1.0
        data[0] = 1.0;

        // e01 (binary 0011 = 3)
        data[3] = -0.5 * x;

        // e02 (binary 0101 = 5)
        data[5] = -0.5 * y;

        // e03 (binary 1001 = 9)
        data[9] = -0.5 * z;

        Self::new(data, Metric::PGA(4)).unwrap()
    }
}
