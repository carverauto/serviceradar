/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::CausalMultiField;
use deep_causality_metric::Metric;
use deep_causality_tensor::CausalTensor;

impl<T> CausalMultiField<T> {
    /// Returns the metric signature of the algebra.
    #[inline]
    pub fn metric(&self) -> Metric {
        self.metric
    }

    /// Returns the grid spacing.
    #[inline]
    pub fn dx(&self) -> &[T; 3] {
        &self.dx
    }

    /// Returns the grid shape [Nx, Ny, Nz].
    #[inline]
    pub fn shape(&self) -> &[usize; 3] {
        &self.shape
    }

    /// Returns the total number of grid cells.
    #[inline]
    pub fn num_cells(&self) -> usize {
        self.shape[0] * self.shape[1] * self.shape[2]
    }

    /// Returns the matrix dimension for the algebra.
    ///
    /// For Cl(p,q,r), the matrix dimension is 2^⌈N/2⌉ where N = p + q + r.
    #[inline]
    pub fn matrix_dim(&self) -> usize {
        let n = self.metric.dimension();
        1 << n.div_ceil(2)
    }

    /// Returns a reference to the underlying tensor.
    #[inline]
    pub fn data(&self) -> &CausalTensor<T> {
        &self.data
    }
}
