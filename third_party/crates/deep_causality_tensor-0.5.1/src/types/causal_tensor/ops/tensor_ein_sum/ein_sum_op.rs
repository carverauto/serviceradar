/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::CausalTensor;
use deep_causality_ast::ConstTree;

// The core enum for the EinSum AST. T is the element type (e.g., Complex<f64>)
pub enum EinSumOp<T> {
    // LEAF: The source Tensor data
    TensorSource {
        tensor: CausalTensor<T>,
    },

    // GENERIC OPS (for flexibility)
    Contraction {
        lhs_axes: Vec<usize>,
        rhs_axes: Vec<usize>,
    },
    Reduction {
        axes: Vec<usize>,
    },

    // EXPLICIT EIN_SUM OPS (for usability)
    /// Standard matrix multiplication (rank-2 tensors)
    MatMul,
    /// Dot product (rank-1 tensors)
    DotProd,
    /// Trace over two specified axes
    Trace {
        axes1: usize,
        axes2: usize,
    },
    /// Outer product
    TensorProduct,
    /// Hadamard product
    ElementWiseProduct,
    Transpose {
        new_order: Vec<usize>,
    },
    DiagonalExtraction {
        axes1: usize,
        axes2: usize,
    },
    /// Batch matrix multiplication (rank-3 tensors)
    BatchMatMul,
}

// The EinSum AST
pub type EinSumAST<T> = ConstTree<EinSumOp<T>>;

impl<T> EinSumOp<T> {
    /// Creates an `EinSumAST` leaf node representing a source `CausalTensor`.
    ///
    /// This is the base case for the AST, where a tensor is directly provided as input.
    ///
    /// # Arguments
    ///
    /// * `tensor` - The `CausalTensor` to be wrapped as a source node.
    ///
    /// # Returns
    ///
    /// An `EinSumAST<T>` node containing the `TensorSource` operation.
    pub fn tensor_source(tensor: CausalTensor<T>) -> EinSumAST<T> {
        EinSumAST::new(EinSumOp::TensorSource { tensor })
    }

    /// Creates an `EinSumAST` node for a generic tensor contraction operation.
    ///
    /// This node represents a contraction between two `CausalTensor`s along specified axes.
    ///
    /// # Arguments
    ///
    /// * `lhs` - The left-hand side `CausalTensor`.
    /// * `rhs` - The right-hand side `CausalTensor`.
    /// * `lhs_axes` - A `Vec<usize>` specifying the axes of the `lhs` tensor to contract.
    /// * `rhs_axes` - A `Vec<usize>` specifying the axes of the `rhs` tensor to contract.
    ///
    /// # Returns
    ///
    /// An `EinSumAST<T>` node representing the contraction operation.
    pub fn contraction<L: Into<CausalTensor<T>>, R: Into<CausalTensor<T>>>(
        lhs: L,
        rhs: R,
        lhs_axes: Vec<usize>,
        rhs_axes: Vec<usize>,
    ) -> EinSumAST<T> {
        let lhs_leaf = EinSumOp::tensor_source(lhs.into());
        let rhs_leaf = EinSumOp::tensor_source(rhs.into());
        EinSumAST::with_children(
            EinSumOp::Contraction { lhs_axes, rhs_axes },
            vec![lhs_leaf, rhs_leaf],
        )
    }

    /// Creates an `EinSumAST` node for a reduction operation.
    ///
    /// This node represents summing elements of a `CausalTensor` along specified axes.
    ///
    /// # Arguments
    ///
    /// * `operand` - The `CausalTensor` to perform the reduction on.
    /// * `axes` - A `Vec<usize>` specifying the axes along which to sum.
    ///
    /// # Returns
    ///
    /// An `EinSumAST<T>` node representing the reduction operation.
    pub fn reduction<O: Into<CausalTensor<T>>>(operand: O, axes: Vec<usize>) -> EinSumAST<T> {
        let operand_leaf = EinSumOp::tensor_source(operand.into());
        EinSumAST::with_children(EinSumOp::Reduction { axes }, vec![operand_leaf])
    }

    /// Creates an `EinSumAST` node for a standard 2D matrix multiplication operation.
    ///
    /// This node represents the multiplication of two rank-2 `CausalTensor`s.
    ///
    /// # Arguments
    ///
    /// * `lhs` - The left-hand side `CausalTensor` (matrix).
    /// * `rhs` - The right-hand side `CausalTensor` (matrix).
    ///
    /// # Returns
    ///
    /// An `EinSumAST<T>` node representing the matrix multiplication operation.
    pub fn mat_mul<L: Into<CausalTensor<T>>, R: Into<CausalTensor<T>>>(
        lhs: L,
        rhs: R,
    ) -> EinSumAST<T> {
        let lhs_leaf = EinSumOp::tensor_source(lhs.into());
        let rhs_leaf = EinSumOp::tensor_source(rhs.into());
        EinSumAST::with_children(EinSumOp::MatMul, vec![lhs_leaf, rhs_leaf])
    }

    /// Creates an `EinSumAST` node for a dot product operation.
    ///
    /// This node represents the dot product of two rank-1 `CausalTensor`s (vectors).
    ///
    /// # Arguments
    ///
    /// * `lhs` - The left-hand side `CausalTensor` (vector).
    /// * `rhs` - The right-hand side `CausalTensor` (vector).
    ///
    /// # Returns
    ///
    /// An `EinSumAST<T>` node representing the dot product operation.
    pub fn dot_prod<L: Into<CausalTensor<T>>, R: Into<CausalTensor<T>>>(
        lhs: L,
        rhs: R,
    ) -> EinSumAST<T> {
        let lhs_leaf = EinSumOp::tensor_source(lhs.into());
        let rhs_leaf = EinSumOp::tensor_source(rhs.into());
        EinSumAST::with_children(EinSumOp::DotProd, vec![lhs_leaf, rhs_leaf])
    }

    /// Creates an `EinSumAST` node for a trace operation.
    ///
    /// This node represents summing the diagonal elements of a `CausalTensor` over two specified axes.
    ///
    /// # Arguments
    ///
    /// * `operand` - The `CausalTensor` to perform the trace on.
    /// * `axes1` - The first axis to trace over.
    /// * `axes2` - The second axis to trace over.
    ///
    /// # Returns
    ///
    /// An `EinSumAST<T>` node representing the trace operation.
    pub fn trace<O: Into<CausalTensor<T>>>(operand: O, axes1: usize, axes2: usize) -> EinSumAST<T> {
        let operand_leaf = EinSumOp::tensor_source(operand.into());
        EinSumAST::with_children(EinSumOp::Trace { axes1, axes2 }, vec![operand_leaf])
    }

    /// Creates an `EinSumAST` node for an outer product (tensor product) operation.
    ///
    /// This node represents the outer product of two `CausalTensor`s.
    ///
    /// # Arguments
    ///
    /// * `lhs` - The left-hand side `CausalTensor`.
    /// * `rhs` - The right-hand side `CausalTensor`.
    ///
    /// # Returns
    ///
    /// An `EinSumAST<T>` node representing the tensor product operation.
    pub fn tensor_product<L: Into<CausalTensor<T>>, R: Into<CausalTensor<T>>>(
        lhs: L,
        rhs: R,
    ) -> EinSumAST<T> {
        let lhs_leaf = EinSumOp::tensor_source(lhs.into());
        let rhs_leaf = EinSumOp::tensor_source(rhs.into());
        EinSumAST::with_children(EinSumOp::TensorProduct, vec![lhs_leaf, rhs_leaf])
    }

    /// Creates an `EinSumAST` node for an element-wise product (Hadamard product) operation.
    ///
    /// This node represents the element-wise multiplication of two `CausalTensor`s.
    ///
    /// # Arguments
    ///
    /// * `lhs` - The left-hand side `CausalTensor`.
    /// * `rhs` - The right-hand side `CausalTensor`.
    ///
    /// # Returns
    ///
    /// An `EinSumAST<T>` node representing the element-wise product operation.
    pub fn element_wise_product<L: Into<CausalTensor<T>>, R: Into<CausalTensor<T>>>(
        lhs: L,
        rhs: R,
    ) -> EinSumAST<T> {
        let lhs_leaf = EinSumOp::tensor_source(lhs.into());
        let rhs_leaf = EinSumOp::tensor_source(rhs.into());
        EinSumAST::with_children(EinSumOp::ElementWiseProduct, vec![lhs_leaf, rhs_leaf])
    }

    /// Creates an `EinSumAST` node for a transpose operation.
    ///
    /// This node represents permuting the axes of a `CausalTensor` according to a new order.
    ///
    /// # Arguments
    ///
    /// * `operand` - The `CausalTensor` to transpose.
    /// * `new_order` - A `Vec<usize>` specifying the new order of axes.
    ///
    /// # Returns
    ///
    /// An `EinSumAST<T>` node representing the transpose operation.
    pub fn transpose<O: Into<CausalTensor<T>>>(operand: O, new_order: Vec<usize>) -> EinSumAST<T> {
        let operand_leaf = EinSumOp::tensor_source(operand.into());
        EinSumAST::with_children(EinSumOp::Transpose { new_order }, vec![operand_leaf])
    }

    /// Creates an `EinSumAST` node for a diagonal extraction operation.
    ///
    /// This node represents extracting the diagonal elements of a `CausalTensor` over two specified axes.
    ///
    /// # Arguments
    ///
    /// * `operand` - The `CausalTensor` from which to extract the diagonal.
    /// * `axes1` - The first axis defining the 2D plane for diagonal extraction.
    /// * `axes2` - The second axis defining the 2D plane for diagonal extraction.
    ///
    /// # Returns
    ///
    /// An `EinSumAST<T>` node representing the diagonal extraction operation.
    pub fn diagonal_extraction<O: Into<CausalTensor<T>>>(
        operand: O,
        axes1: usize,
        axes2: usize,
    ) -> EinSumAST<T> {
        let operand_leaf = EinSumOp::tensor_source(operand.into());
        EinSumAST::with_children(
            EinSumOp::DiagonalExtraction { axes1, axes2 },
            vec![operand_leaf],
        )
    }

    /// Creates an `EinSumAST` node for a batch matrix multiplication operation.
    ///
    /// This node represents performing matrix multiplication on batches of `CausalTensor`s.
    ///
    /// # Arguments
    ///
    /// * `lhs` - The left-hand side `CausalTensor` with a batch dimension.
    /// * `rhs` - The right-hand side `CausalTensor` with a batch dimension.
    ///
    /// # Returns
    ///
    /// An `EinSumAST<T>` node representing the batch matrix multiplication operation.
    pub fn batch_mat_mul<L: Into<CausalTensor<T>>, R: Into<CausalTensor<T>>>(
        lhs: L,
        rhs: R,
    ) -> EinSumAST<T> {
        let lhs_leaf = EinSumOp::tensor_source(lhs.into());
        let rhs_leaf = EinSumOp::tensor_source(rhs.into());
        EinSumAST::with_children(EinSumOp::BatchMatMul, vec![lhs_leaf, rhs_leaf])
    }
}
