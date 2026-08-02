/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::CsrMatrix;
use deep_causality_algebra::{AbelianGroup, Ring};
use deep_causality_num::{One, Zero};
use std::ops::Neg;

// Implements Zero trait for CsrMatrix.
// Returns an empty (0,0) matrix, representing a scalar zero.
impl<T> Zero for CsrMatrix<T>
where
    // These bounds are needed for CsrMatrix<T> to satisfy Add<Self> required by Zero.
    // T itself needs to be AbelianGroup for CsrMatrix's Add impl.
    // Neg is needed for element-wise negation in CsrMatrix's neg method.
    T: Zero + Copy + Default + PartialEq + AbelianGroup + Neg<Output = T>,
{
    fn zero() -> Self {
        // Scalar zero matrix is an empty matrix with no rows/cols
        Self {
            row_indices: vec![0],
            col_indices: Vec::new(),
            values: Vec::new(),
            shape: (0, 0),
        }
    }

    fn is_zero(&self) -> bool {
        self.values.iter().all(|x| x.is_zero()) && self.values.is_empty()
    }
}

// Implements One trait for CsrMatrix.
// Returns a (1,1) identity matrix, representing a scalar one.
impl<T> One for CsrMatrix<T>
where
    // These bounds are needed for CsrMatrix<T> to satisfy Mul<Self> required by One.
    // T itself needs to be Ring for CsrMatrix's Mul impl.
    T: One + Copy + Default + PartialEq + Ring + std::ops::AddAssign,
{
    fn one() -> Self {
        // Scalar one matrix is a 1x1 identity matrix
        Self {
            row_indices: vec![0, 1],
            col_indices: vec![0],
            values: vec![T::one()],
            shape: (1, 1),
        }
    }

    fn is_one(&self) -> bool {
        self.shape == (1, 1) && self.values.len() == 1 && self.values[0].is_one()
    }
}
