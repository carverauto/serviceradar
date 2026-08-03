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
    /// The conjugate transpose (Hermitian adjoint) `Aᴴ` of a 2-dimensional tensor: the element
    /// at `(i, j)` becomes the conjugate of the element at `(j, i)`. For a real scalar the
    /// conjugation is the identity and this is the ordinary transpose.
    ///
    /// # Errors
    /// Returns [`CausalTensorError::DimensionMismatch`] if `self` is not 2-dimensional, or
    /// [`CausalTensorError::EmptyTensor`] if either dimension is zero.
    pub fn dagger(&self) -> Result<Self, CausalTensorError> {
        if self.shape().len() != 2 {
            return Err(CausalTensorError::DimensionMismatch);
        }
        let m = self.shape()[0];
        let n = self.shape()[1];
        if m == 0 || n == 0 {
            return Err(CausalTensorError::EmptyTensor);
        }
        let a = self.as_slice();
        let mut out = vec![T::zero(); n * m];
        for i in 0..m {
            for j in 0..n {
                out[j * m + i] = a[i * n + j].conjugate();
            }
        }
        CausalTensor::new(out, vec![n, m])
    }
}
