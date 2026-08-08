/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use deep_causality_algebra::{Field, Ring};
use deep_causality_tensor::{CausalTensor, Tensor};

/// Trait to support batched matrix multiplication.
pub trait BatchedMatMul<T>
where
    T: Field + Ring + Copy + Default + PartialOrd,
{
    fn batched_matmul(&self, other: &Self) -> Self;
}

impl<T> BatchedMatMul<T> for CausalTensor<T>
where
    T: Field + Ring + Copy + Default + PartialOrd,
{
    fn batched_matmul(&self, other: &Self) -> Self {
        let shape = self.shape().to_vec();
        let rank = shape.len();

        if rank < 3 {
            // Fallback for purely 2D - use matmul method
            return self.matmul(other).expect("matmul failed in batched_matmul");
        }

        let d_rows = shape[rank - 2];
        let d_cols = shape[rank - 1];
        let batch_dims = &shape[0..rank - 2];
        let batch_size: usize = batch_dims.iter().product();

        // Reshape to [Batch, D, D]
        let a_flat = self
            .reshape(&[batch_size, d_rows, d_cols])
            .expect("reshape failed");
        let b_flat = other
            .reshape(&[batch_size, d_rows, d_cols])
            .expect("reshape failed");

        // Loop over batches
        let mut results = Vec::with_capacity(batch_size);
        for i in 0..batch_size {
            // Use slice(axis, index) method
            let a_slice = a_flat.slice(0, i).expect("slice failed");
            let b_slice = b_flat.slice(0, i).expect("slice failed");

            let c_mat = a_slice.matmul(&b_slice).expect("matmul failed");
            results.push(c_mat);
        }

        // Stack results back - stack takes &[Self]
        let stacked = CausalTensor::stack(&results, 0).expect("Stack failed during batched matmul");

        // Reshape back to original shape
        stacked.reshape(&shape).expect("reshape failed")
    }
}
