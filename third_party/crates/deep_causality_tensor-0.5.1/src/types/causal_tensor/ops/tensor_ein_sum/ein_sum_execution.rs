/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::Tensor;
use crate::{CausalTensor, CausalTensorError, EinSumAST, EinSumOp};
use std::ops::{Add, Mul};

impl<T> CausalTensor<T>
where
    T: Clone + Default + PartialOrd + Add<Output = T> + Mul<Output = T>,
{
    /// Executes the Einstein summation by recursively traversing the AST.
    ///
    /// This private method interprets the `EinSumAST` nodes and dispatches to the
    /// appropriate tensor operation functions (e.g., `contract`, `mat_mul_2d`, `trace`).
    /// It handles both leaf nodes (TensorSource) and operational nodes with children.
    ///
    /// # Arguments
    ///
    /// * `ast` - A reference to the `EinSumAST` node currently being executed.
    ///
    /// # Returns
    ///
    /// A `Result` which is:
    /// - `Ok(CausalTensor<T>)` containing the result of the operation defined by the AST node.
    /// - `Err(CausalTensorError)` if any error occurs during the execution of the current node
    ///   or its children.
    ///
    /// # Errors
    ///
    /// Returns errors propagated from helper functions like `get_binary_operands`,
    /// `get_unary_operand`, `contract`, `sum_axes`, `mat_mul_2d`, `tensor_product`,
    /// `element_wise_mul`, `permute_axes`, `diagonal`, and `batch_mat_mul`.
    pub(crate) fn execute_ein_sum(
        ast: &EinSumAST<T>,
    ) -> Result<CausalTensor<T>, CausalTensorError> {
        let node = ast.value();
        let children = ast.children();

        match node {
            EinSumOp::TensorSource { tensor } => Ok(tensor.clone()),

            // Generic Ops
            EinSumOp::Contraction { lhs_axes, rhs_axes } => {
                let (lhs, rhs) = Self::get_binary_operands(children)?;
                Self::contract(&lhs, &rhs, lhs_axes, rhs_axes)
            }
            EinSumOp::Reduction { axes } => {
                let operand = Self::get_unary_operand(children)?;
                operand.sum_axes(axes)
            }

            // Explicit Ops
            EinSumOp::MatMul => {
                let (lhs, rhs) = Self::get_binary_operands(children)?;
                Self::mat_mul_2d(&lhs, &rhs)
            }
            EinSumOp::DotProd => {
                let (lhs, rhs) = Self::get_binary_operands(children)?;
                Self::contract(&lhs, &rhs, &[0], &[0]) // Contract the single axis of both vectors
            }
            EinSumOp::Trace { axes1, axes2 } => {
                let operand = Self::get_unary_operand(children)?;
                Self::trace(&operand, *axes1, *axes2)
            }
            EinSumOp::TensorProduct => {
                let (lhs, rhs) = Self::get_binary_operands(children)?;
                lhs.tensor_product(&rhs)
            }
            EinSumOp::ElementWiseProduct => {
                let (lhs, rhs) = Self::get_binary_operands(children)?;
                Self::element_wise_mul(&lhs, &rhs)
            }
            EinSumOp::Transpose { new_order } => {
                let operand = Self::get_unary_operand(children)?;
                operand.permute_axes(new_order)
            }
            EinSumOp::DiagonalExtraction { axes1, axes2 } => {
                let operand = Self::get_unary_operand(children)?;
                Self::diagonal(&operand, *axes1, *axes2)
            }
            EinSumOp::BatchMatMul => {
                let (lhs, rhs) = Self::get_binary_operands(children)?;
                Self::batch_mat_mul(lhs, rhs)
            }
        }
    }
}
