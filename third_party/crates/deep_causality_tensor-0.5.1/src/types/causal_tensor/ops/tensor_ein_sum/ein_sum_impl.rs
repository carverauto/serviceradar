/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::Tensor;
use crate::{CausalTensor, CausalTensorError, EinSumAST, EinSumValidationError};
use std::ops::{Add, Mul};

impl<T> CausalTensor<T>
where
    T: Clone + Default + PartialOrd + Add<Output = T> + Mul<Output = T>,
{
    /// Extracts two operands from the provided Abstract Syntax Tree (AST) children.
    ///
    /// This helper function is used to retrieve the left-hand side (LHS) and right-hand side (RHS)
    /// `CausalTensor` operands from a slice of `EinSumAST` nodes. It expects exactly two children
    /// in the AST slice.
    ///
    /// # Arguments
    ///
    /// * `children` - A slice of `EinSumAST<T>` representing the children nodes of an AST operation.
    ///
    /// Expected to contain exactly two elements, each resolving to a `CausalTensor<T>`.
    ///
    /// # Returns
    ///
    /// A `Result` which is:
    /// - `Ok((CausalTensor<T>, CausalTensor<T>))` containing the LHS and RHS tensors if successful.
    /// - `Err(CausalTensorError)` if the number of children is not two, or if `execute_ein_sum`
    ///   fails for either child.
    ///
    /// # Errors
    ///
    /// Returns `CausalTensorError::EinSumError(EinSumValidationError::InvalidNumberOfChildren)`
    /// if `children.len()` is not equal to 2.
    /// Returns errors propagated from `CausalTensor::execute_ein_sum`.
    pub(in crate::types::causal_tensor) fn get_binary_operands(
        children: &[EinSumAST<T>],
    ) -> Result<(CausalTensor<T>, CausalTensor<T>), CausalTensorError> {
        if children.len() != 2 {
            return Err(CausalTensorError::EinSumError(
                EinSumValidationError::InvalidNumberOfChildren {
                    expected: 2,
                    found: children.len(),
                },
            ));
        }
        let lhs = CausalTensor::execute_ein_sum(&children[0])?;
        let rhs = CausalTensor::execute_ein_sum(&children[1])?;
        Ok((lhs, rhs))
    }

    /// Extracts a single operand from the provided Abstract Syntax Tree (AST) children.
    ///
    /// This helper function is used to retrieve a single `CausalTensor` operand from a slice
    /// of `EinSumAST` nodes. It expects exactly one child in the AST slice.
    ///
    /// # Arguments
    ///
    /// * `children` - A slice of `EinSumAST<T>` representing the children nodes of an AST operation.
    ///
    /// Expected to contain exactly one element, resolving to a `CausalTensor<T>`.
    ///
    /// # Returns
    ///
    /// A `Result` which is:
    /// - `Ok(CausalTensor<T>)` containing the single operand tensor if successful.
    /// - `Err(CausalTensorError)` if the number of children is not one, or if `execute_ein_sum`
    ///   fails for the child.
    ///
    /// # Errors
    ///
    /// Returns `CausalTensorError::EinSumError(EinSumValidationError::InvalidNumberOfChildren)`
    /// if `children.len()` is not equal to 1.
    /// Returns errors propagated from `CausalTensor::execute_ein_sum`.
    pub(in crate::types::causal_tensor) fn get_unary_operand(
        children: &[EinSumAST<T>],
    ) -> Result<CausalTensor<T>, CausalTensorError> {
        if children.len() != 1 {
            return Err(CausalTensorError::EinSumError(
                EinSumValidationError::InvalidNumberOfChildren {
                    expected: 1,
                    found: children.len(),
                },
            ));
        }
        CausalTensor::execute_ein_sum(&children[0])
    }

    /// Performs a generic tensor contraction between two `CausalTensor`s.
    ///
    /// This method implements an optimized tensor contraction by leveraging permutation and
    /// reshaping operations to reduce the problem to a standard 2D matrix multiplication.
    /// It identifies common axes between the two tensors and sums over their products.
    ///
    /// # Arguments
    ///
    /// * `lhs` - The left-hand side `CausalTensor`.
    /// * `rhs` - The right-hand side `CausalTensor`.
    /// * `lhs_contract_axes` - A slice of `usize` indicating the axes of `lhs` to contract over.
    /// * `rhs_contract_axes` - A slice of `usize` indicating the axes of `rhs` to contract over.
    ///
    /// # Returns
    ///
    /// A `Result` which is:
    /// - `Ok(CausalTensor<T>)` containing the result of the tensor contraction.
    /// - `Err(CausalTensorError)` if validation fails or an underlying operation encounters an error.
    ///
    /// # Errors
    ///
    /// Returns `CausalTensorError::EinSumError` if:
    /// - The number of `lhs_contract_axes` and `rhs_contract_axes` do not match.
    /// - Any specified axis is out of bounds for its respective tensor.
    /// - The dimensions of the contracted axes in `lhs` and `rhs` do not match.
    /// - Errors are propagated from `permute_axes`, `reshape`, or `mat_mul_2d`.
    pub(in crate::types::causal_tensor) fn contract(
        lhs: &CausalTensor<T>,
        rhs: &CausalTensor<T>,
        lhs_contract_axes: &[usize],
        rhs_contract_axes: &[usize],
    ) -> Result<CausalTensor<T>, CausalTensorError> {
        // 1. Validate input axes and shapes
        if lhs_contract_axes.len() != rhs_contract_axes.len() {
            return Err(CausalTensorError::EinSumError(
                EinSumValidationError::InvalidAxesSpecification {
                    message: "Number of LHS and RHS contraction axes must match".to_string(),
                },
            ));
        }

        for (&lhs_axis, &rhs_axis) in lhs_contract_axes.iter().zip(rhs_contract_axes.iter()) {
            if lhs_axis >= lhs.num_dim() || rhs_axis >= rhs.num_dim() {
                return Err(CausalTensorError::EinSumError(
                    EinSumValidationError::InvalidAxesSpecification {
                        message: format!(
                            "Axis out of bounds: lhs_axis {} (dim {}), rhs_axis {} (dim {})",
                            lhs_axis,
                            lhs.num_dim(),
                            rhs_axis,
                            rhs.num_dim()
                        ),
                    },
                ));
            }
            if lhs.shape[lhs_axis] != rhs.shape[rhs_axis] {
                return Err(CausalTensorError::EinSumError(
                    EinSumValidationError::ShapeMismatch {
                        message: format!(
                            "Contracted axes have mismatched dimensions: lhs_axis {} (dim {}), rhs_axis {} (dim {})",
                            lhs_axis, lhs.shape[lhs_axis], rhs_axis, rhs.shape[rhs_axis]
                        ),
                    },
                ));
            }
        }

        // 2. Identify remaining (uncontracted) axes and build permutation maps
        let lhs_remaining_axes: Vec<usize> = (0..lhs.num_dim())
            .filter(|&i| !lhs_contract_axes.contains(&i))
            .collect();
        let rhs_remaining_axes: Vec<usize> = (0..rhs.num_dim())
            .filter(|&i| !rhs_contract_axes.contains(&i))
            .collect();

        // Create permutation for LHS: (remaining_lhs, contracted_lhs)
        let mut lhs_perm_order = lhs_remaining_axes.clone();
        lhs_perm_order.extend_from_slice(lhs_contract_axes);

        // Create permutation for RHS: (contracted_rhs, remaining_rhs)
        let mut rhs_perm_order = rhs_contract_axes.to_vec();
        rhs_perm_order.extend_from_slice(&rhs_remaining_axes);

        // 3. Permute and reshape tensors
        let permuted_lhs = lhs.permute_axes(&lhs_perm_order)?;
        let permuted_rhs = rhs.permute_axes(&rhs_perm_order)?;

        let contracted_dim_size: usize =
            lhs_contract_axes.iter().map(|&ax| lhs.shape[ax]).product();

        let lhs_rows: usize = lhs_remaining_axes.iter().map(|&ax| lhs.shape[ax]).product();
        let rhs_cols: usize = rhs_remaining_axes.iter().map(|&ax| rhs.shape[ax]).product();

        let reshaped_lhs = permuted_lhs.reshape(&[lhs_rows, contracted_dim_size])?;
        let reshaped_rhs = permuted_rhs.reshape(&[contracted_dim_size, rhs_cols])?;

        // 4. Perform matrix multiplication
        let result_matrix = Self::mat_mul_2d(&reshaped_lhs, &reshaped_rhs)?;

        // 5. Reshape result back to final tensor shape
        let mut final_shape = Vec::new();
        final_shape.extend(lhs_remaining_axes.iter().map(|&ax| lhs.shape[ax]));
        final_shape.extend(rhs_remaining_axes.iter().map(|&ax| rhs.shape[ax]));

        result_matrix.reshape(&final_shape)
    }

    /// Performs 2D matrix multiplication between two `CausalTensor`s.
    ///
    /// This private helper function computes the matrix product of two rank-2 tensors.
    /// It validates that both input tensors are indeed 2D and that their inner dimensions
    /// are compatible for multiplication (i.e., `lhs.cols == rhs.rows`).
    ///
    /// # Arguments
    ///
    /// * `lhs` - The left-hand side `CausalTensor` (matrix).
    /// * `rhs` - The right-hand side `CausalTensor` (matrix).
    ///
    /// # Returns
    ///
    /// A `Result` which is:
    /// - `Ok(CausalTensor<T>)` containing the resulting product matrix.
    /// - `Err(CausalTensorError)` if validation fails.
    ///
    /// # Errors
    ///
    /// Returns `CausalTensorError::EinSumError` if:
    /// - Either `lhs` or `rhs` is not a 2D tensor (rank mismatch).
    /// - The inner dimensions of `lhs` and `rhs` do not match (shape mismatch).
    pub(in crate::types::causal_tensor) fn mat_mul_2d(
        lhs: &CausalTensor<T>,
        rhs: &CausalTensor<T>,
    ) -> Result<CausalTensor<T>, CausalTensorError> {
        if lhs.num_dim() != 2 {
            return Err(CausalTensorError::EinSumError(
                EinSumValidationError::RankMismatch {
                    expected: 2,
                    found: lhs.num_dim(),
                },
            ));
        }
        if rhs.num_dim() != 2 {
            return Err(CausalTensorError::EinSumError(
                EinSumValidationError::RankMismatch {
                    expected: 2,
                    found: rhs.num_dim(),
                },
            ));
        }
        if lhs.shape[1] != rhs.shape[0] {
            return Err(CausalTensorError::EinSumError(
                EinSumValidationError::ShapeMismatch {
                    message: format!(
                        "Matrix dimensions mismatch for multiplication: {} vs {}",
                        lhs.shape[1], rhs.shape[0]
                    ),
                },
            ));
        }

        let m = lhs.shape[0];
        let k = lhs.shape[1]; // Also rhs.shape[0]
        let n = rhs.shape[1];

        let mut result_data = vec![T::default(); m * n];

        let lhs_row_stride_i = lhs.strides[0];
        let lhs_col_stride = lhs.strides[1];
        let rhs_row_stride = rhs.strides[0];
        let rhs_col_stride_j = rhs.strides[1];

        for i in 0..m {
            let lhs_row_base = i * lhs_row_stride_i;
            for j in 0..n {
                let rhs_col_base = j * rhs_col_stride_j;
                let mut sum = T::default();
                for l in 0..k {
                    let lhs_idx = lhs_row_base + l * lhs_col_stride;
                    let rhs_idx = l * rhs_row_stride + rhs_col_base;
                    let lhs_val = lhs.data[lhs_idx].clone();
                    let rhs_val = rhs.data[rhs_idx].clone();
                    sum = sum + lhs_val * rhs_val;
                }
                result_data[i * n + j] = sum;
            }
        }

        CausalTensor::new(result_data, vec![m, n])
    }

    /// Performs element-wise multiplication (Hadamard product) between two `CausalTensor`s.
    ///
    /// This private method multiplies corresponding elements of two tensors. It leverages
    /// the `broadcast_op` method to handle broadcasting rules if the tensor shapes are not identical.
    ///
    /// # Arguments
    ///
    /// * `lhs` - The left-hand side `CausalTensor`.
    /// * `rhs` - The right-hand side `CausalTensor`.
    ///
    /// # Returns
    ///
    /// A `Result` which is:
    /// - `Ok(CausalTensor<T>)` containing the result of the element-wise multiplication.
    /// - `Err(CausalTensorError)` if broadcasting fails or an element-wise operation encounters an error.
    ///
    /// # Errors
    ///
    /// Returns errors propagated from `CausalTensor::broadcast_op`.
    pub(in crate::types::causal_tensor) fn element_wise_mul(
        lhs: &CausalTensor<T>,
        rhs: &CausalTensor<T>,
    ) -> Result<CausalTensor<T>, CausalTensorError> {
        lhs.broadcast_op(rhs, |a, b| Ok(a * b))
    }

    /// Computes the trace of a `CausalTensor` over two specified axes.
    ///
    /// The trace operation sums the elements along the diagonal of a 2D slice
    /// defined by `axis1` and `axis2`. If the tensor has more than two dimensions,
    /// this operation is applied to all 2D slices formed by the specified axes,
    /// effectively reducing the tensor's rank by two.
    ///
    /// # Arguments
    ///
    /// * `tensor` - The input `CausalTensor`.
    /// * `axis1` - The first axis to trace over.
    /// * `axis2` - The second axis to trace over.
    ///
    /// # Returns
    ///
    /// A `Result` which is:
    /// - `Ok(CausalTensor<T>)` containing the result of the trace operation.
    /// - `Err(CausalTensorError)` if validation fails.
    ///
    /// # Errors
    ///
    /// Returns `CausalTensorError::EinSumError` if:
    /// - `axis1` or `axis2` are out of bounds for the tensor's dimensions.
    /// - `axis1` and `axis2` are identical.
    /// - The dimensions of `axis1` and `axis2` are not equal (shape mismatch).
    pub(in crate::types::causal_tensor) fn trace(
        tensor: &CausalTensor<T>,
        axis1: usize,
        axis2: usize,
    ) -> Result<CausalTensor<T>, CausalTensorError> {
        if axis1 >= tensor.num_dim() || axis2 >= tensor.num_dim() || axis1 == axis2 {
            return Err(CausalTensorError::EinSumError(
                EinSumValidationError::InvalidAxesSpecification {
                    message: format!("Invalid trace axes: {}, {}", axis1, axis2),
                },
            ));
        }
        if tensor.shape[axis1] != tensor.shape[axis2] {
            return Err(CausalTensorError::EinSumError(
                EinSumValidationError::ShapeMismatch {
                    message: format!(
                        "Trace axes have mismatched dimensions: axis {} (dim {}), axis {} (dim {})",
                        axis1, tensor.shape[axis1], axis2, tensor.shape[axis2]
                    ),
                },
            ));
        }

        let new_shape: Vec<usize> = tensor
            .shape
            .iter()
            .enumerate()
            .filter(|&(i, _)| i != axis1 && i != axis2)
            .map(|(_, &dim)| dim)
            .collect();

        if new_shape.is_empty() {
            // This is a 2D tensor trace, resulting in a scalar.
            let mut total_sum = T::default();
            let dim = tensor.shape[axis1];
            let stride1 = tensor.strides[axis1];
            let stride2 = tensor.strides[axis2];

            for i in 0..dim {
                let flat_index = i * stride1 + i * stride2;
                total_sum = total_sum + tensor.data[flat_index].clone();
            }
            return CausalTensor::new(vec![total_sum], vec![]);
        }

        let mut result_tensor = CausalTensor::full(&new_shape, T::default());
        let diag_len = tensor.shape[axis1];

        let mut batch_axes = Vec::new();
        for i in 0..tensor.num_dim() {
            if i != axis1 && i != axis2 {
                batch_axes.push(i);
            }
        }

        let num_batch_elements: usize = batch_axes.iter().map(|&ax| tensor.shape[ax]).product();
        let mut current_batch_indices = vec![0; batch_axes.len()];

        for _ in 0..num_batch_elements {
            let result_index = current_batch_indices.clone();
            if let Some(res_val) = result_tensor.get_mut(&result_index) {
                let mut batch_offset = 0;
                for (k, &batch_axis) in batch_axes.iter().enumerate() {
                    batch_offset += current_batch_indices[k] * tensor.strides[batch_axis];
                }

                let mut diag_sum = T::default();
                for i in 0..diag_len {
                    let flat_index =
                        batch_offset + i * tensor.strides[axis1] + i * tensor.strides[axis2];
                    diag_sum = diag_sum + tensor.data[flat_index].clone();
                }
                *res_val = diag_sum;
            }

            // Increment batch indices
            let mut k = batch_axes.len();
            while k > 0 {
                k -= 1;
                current_batch_indices[k] += 1;
                if current_batch_indices[k] < tensor.shape[batch_axes[k]] {
                    break;
                }
                current_batch_indices[k] = 0;
            }
        }

        Ok(result_tensor)
    }

    /// Extracts the diagonal elements of a `CausalTensor` over two specified axes.
    ///
    /// This private method extracts the diagonal elements from 2D slices of the input tensor
    /// defined by `axis1` and `axis2`. The resulting tensor will have a rank reduced by one
    /// compared to the input tensor, with the new last dimension representing the diagonal.
    ///
    /// # Arguments
    ///
    /// * `tensor` - The input `CausalTensor`.
    /// * `axis1` - The first axis defining the 2D plane from which to extract the diagonal.
    /// * `axis2` - The second axis defining the 2D plane from which to extract the diagonal.
    ///
    /// # Returns
    ///
    /// A `Result` which is:
    /// - `Ok(CausalTensor<T>)` containing the tensor with extracted diagonal elements.
    /// - `Err(CausalTensorError)` if validation fails.
    ///
    /// # Errors
    ///
    /// Returns `CausalTensorError::EinSumError` if:
    /// - `axis1` or `axis2` are out of bounds for the tensor's dimensions.
    /// - `axis1` and `axis2` are identical.
    /// - The dimensions of `axis1` and `axis2` are not equal (shape mismatch).
    pub(in crate::types::causal_tensor) fn diagonal(
        tensor: &CausalTensor<T>,
        axis1: usize,
        axis2: usize,
    ) -> Result<CausalTensor<T>, CausalTensorError> {
        if axis1 >= tensor.num_dim() || axis2 >= tensor.num_dim() || axis1 == axis2 {
            return Err(CausalTensorError::EinSumError(
                EinSumValidationError::InvalidAxesSpecification {
                    message: format!("Invalid diagonal axes: {}, {}", axis1, axis2),
                },
            ));
        }
        if tensor.shape[axis1] != tensor.shape[axis2] {
            return Err(CausalTensorError::EinSumError(
                EinSumValidationError::ShapeMismatch {
                    message: format!(
                        "Diagonal axes have mismatched dimensions: axis {} (dim {}), axis {} (dim {})",
                        axis1, tensor.shape[axis1], axis2, tensor.shape[axis2]
                    ),
                },
            ));
        }

        let diag_len = tensor.shape[axis1];
        let mut new_shape = Vec::new();
        let mut batch_axes = Vec::new();

        for i in 0..tensor.num_dim() {
            if i != axis1 && i != axis2 {
                new_shape.push(tensor.shape[i]);
                batch_axes.push(i);
            }
        }
        new_shape.push(diag_len); // Add the diagonal dimension

        let mut result_data = Vec::with_capacity(new_shape.iter().product());
        let mut current_batch_indices = vec![0; batch_axes.len()];

        // Iterate over all combinations of batch indices
        let num_batch_elements: usize = batch_axes.iter().map(|&ax| tensor.shape[ax]).product();

        for _ in 0..num_batch_elements {
            for i in 0..diag_len {
                let mut current_full_index = vec![0; tensor.num_dim()];
                current_full_index[axis1] = i;
                current_full_index[axis2] = i;

                // Fill in batch indices
                for (j, &batch_axis) in batch_axes.iter().enumerate() {
                    current_full_index[batch_axis] = current_batch_indices[j];
                }
                result_data.push(tensor.get(&current_full_index).unwrap().clone());
            }

            // Increment batch indices
            let mut k = batch_axes.len();
            while k > 0 {
                k -= 1;
                current_batch_indices[k] += 1;
                if current_batch_indices[k] < tensor.shape[batch_axes[k]] {
                    break;
                }
                current_batch_indices[k] = 0;
            }
        }

        CausalTensor::new(result_data, new_shape)
    }

    /// Performs batch matrix multiplication between two `CausalTensor`s.
    ///
    /// This method expects both input tensors to have at least 3 dimensions, where the first
    /// dimension represents the batch size. It performs a 2D matrix multiplication for each
    /// corresponding pair of matrices within the batch and stacks the results.
    ///
    /// # Arguments
    ///
    /// * `lhs` - The left-hand side `CausalTensor` with a batch dimension.
    /// * `rhs` - The right-hand side `CausalTensor` with a batch dimension.
    ///
    /// # Returns
    ///
    /// A `Result` which is:
    /// - `Ok(CausalTensor<T>)` containing the result of the batch matrix multiplication.
    /// - `Err(CausalTensorError)` if validation fails or an underlying operation encounters an error.
    ///
    /// # Errors
    ///
    /// Returns `CausalTensorError::EinSumError` if:
    /// - Either `lhs` or `rhs` has fewer than 3 dimensions (rank mismatch).
    /// - The batch sizes of `lhs` and `rhs` do not match (shape mismatch).
    /// - Errors are propagated from `slice`, `mat_mul_2d`, or `stack`.
    pub(in crate::types::causal_tensor) fn batch_mat_mul(
        lhs: CausalTensor<T>,
        rhs: CausalTensor<T>,
    ) -> Result<CausalTensor<T>, CausalTensorError> {
        if lhs.num_dim() < 3 {
            return Err(CausalTensorError::EinSumError(
                EinSumValidationError::RankMismatch {
                    expected: 3,
                    found: lhs.num_dim(),
                },
            ));
        }
        if rhs.num_dim() < 3 {
            return Err(CausalTensorError::EinSumError(
                EinSumValidationError::RankMismatch {
                    expected: 3,
                    found: rhs.num_dim(),
                },
            ));
        }

        let batch_size = lhs.shape()[0];
        if batch_size != rhs.shape()[0] {
            return Err(CausalTensorError::EinSumError(
                EinSumValidationError::ShapeMismatch {
                    message: format!(
                        "Batch dimensions mismatch: lhs batch {} vs rhs batch {}",
                        batch_size,
                        rhs.shape()[0]
                    ),
                },
            ));
        }

        let mut result_batches = Vec::with_capacity(batch_size);

        for i in 0..batch_size {
            let lhs_batch = lhs.slice(0, i)?;
            let rhs_batch = rhs.slice(0, i)?;
            let result_batch = Self::mat_mul_2d(&lhs_batch, &rhs_batch)?;
            result_batches.push(result_batch);
        }

        // Stack the results back into a single tensor
        CausalTensor::stack_impl(&result_batches, 0)
    }
}
