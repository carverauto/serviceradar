/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::CausalTensorError;
use crate::types::causal_tensor::CausalTensor;
use deep_causality_algebra::ConjugateScalar;

impl<T> CausalTensor<T>
where
    T: ConjugateScalar,
{
    /// The Kronecker (tensor) product `A ⊗ B` of two 2-dimensional tensors: for an `m₁×n₁` `A`
    /// and an `m₂×n₂` `B`, the result is the `(m₁·m₂)×(n₁·n₂)` block matrix whose `(i₁, j₁)`
    /// block is `A[i₁, j₁] · B`, i.e.
    /// `(A ⊗ B)[i₁·m₂ + i₂, j₁·n₂ + j₂] = A[i₁, j₁] · B[i₂, j₂]`.
    ///
    /// # Reference
    /// R. A. Horn and C. R. Johnson, *Topics in Matrix Analysis* (Cambridge Univ. Press, 1991),
    /// ch. 4 (the Kronecker product).
    ///
    /// # Errors
    /// Returns [`CausalTensorError::DimensionMismatch`] if either operand is not 2-dimensional,
    /// or [`CausalTensorError::EmptyTensor`] if any dimension is zero.
    pub fn kronecker(&self, rhs: &Self) -> Result<Self, CausalTensorError> {
        if self.shape().len() != 2 || rhs.shape().len() != 2 {
            return Err(CausalTensorError::DimensionMismatch);
        }
        let m1 = self.shape()[0];
        let n1 = self.shape()[1];
        let m2 = rhs.shape()[0];
        let n2 = rhs.shape()[1];
        if m1 == 0 || n1 == 0 || m2 == 0 || n2 == 0 {
            return Err(CausalTensorError::EmptyTensor);
        }
        let a = self.as_slice();
        let b = rhs.as_slice();
        let rows = m1 * m2;
        let cols = n1 * n2;
        let mut out = vec![T::zero(); rows * cols];
        for i1 in 0..m1 {
            for j1 in 0..n1 {
                let scale = a[i1 * n1 + j1];
                for i2 in 0..m2 {
                    let row = i1 * m2 + i2;
                    for j2 in 0..n2 {
                        let col = j1 * n2 + j2;
                        out[row * cols + col] = scale * b[i2 * n2 + j2];
                    }
                }
            }
        }
        CausalTensor::new(out, vec![rows, cols])
    }
}
