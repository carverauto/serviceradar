/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{CausalTensor, CausalTensorError, EinSumOp};
use deep_causality_algebra::Ring;
use std::ops::Mul;

impl<T> CausalTensor<T>
where
    T: Ring + Copy + Default + PartialOrd,
{
    pub(in crate::types::causal_tensor) fn matmul_impl(
        &self,
        rhs: &Self,
    ) -> Result<Self, CausalTensorError> {
        // Construct AST for Matrix Multiplication
        let ast = EinSumOp::mat_mul(self.clone(), rhs.clone());
        // Execute via internal engine
        Self::execute_ein_sum(&ast)
    }
}

impl<T> CausalTensor<T>
where
    T: Clone + Mul<Output = T>,
{
    pub(in crate::types::causal_tensor) fn tensor_product_impl(
        &self,
        rhs: &CausalTensor<T>,
    ) -> Result<CausalTensor<T>, CausalTensorError> {
        if self.is_empty() || rhs.is_empty() {
            return Err(CausalTensorError::EmptyTensor);
        }

        // Calculate the new shape by concatenating the shapes of self and rhs.
        let mut result_shape = Vec::with_capacity(self.num_dim() + rhs.num_dim());
        result_shape.extend_from_slice(self.shape());
        result_shape.extend_from_slice(rhs.shape());

        let result_len = self.len() * rhs.len();
        let mut result_data = Vec::with_capacity(result_len);

        // Iterate through all elements of self and rhs, performing the multiplication.
        for self_val in self.data.iter() {
            for rhs_val in rhs.data.iter() {
                result_data.push(self_val.clone() * rhs_val.clone());
            }
        }

        CausalTensor::new(result_data, result_shape)
    }
}
