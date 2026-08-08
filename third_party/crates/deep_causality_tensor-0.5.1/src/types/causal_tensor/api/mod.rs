/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{CausalTensor, CausalTensorError, EinSumAST, Tensor};
use core::iter::Sum;
use core::ops::{Add, Div, Mul};
use deep_causality_algebra::{RealField, Ring};
use deep_causality_num::{One, Zero};

impl<T> Tensor<T> for CausalTensor<T> {
    /// Public API for Einstein summation.
    ///
    /// This method serves as the entry point for performing Einstein summation operations
    /// on `CausalTensor`s. It takes an `EinSumAST` (Abstract Syntax Tree) as input,
    /// which defines the sequence of tensor operations to be executed.
    ///
    /// # Arguments
    ///
    /// * `ast` - A reference to the `EinSumAST` that describes the Einstein summation operation.
    ///
    /// # Returns
    ///
    /// A `Result` which is:
    /// - `Ok(CausalTensor<T>)` containing the result of the Einstein summation.
    /// - `Err(CausalTensorError)` if any error occurs during the execution of the AST.
    ///
    /// # Errors
    ///
    /// Returns errors propagated from `execute_ein_sum`.
    fn ein_sum(ast: &EinSumAST<T>) -> Result<CausalTensor<T>, CausalTensorError>
    where
        T: Clone + Default + PartialOrd + Add<Output = T> + Mul<Output = T>,
    {
        Self::execute_ein_sum(ast)
    }

    fn matmul(&self, rhs: &Self) -> Result<Self, CausalTensorError>
    where
        T: Ring + Copy + Default + PartialOrd,
    {
        self.matmul_impl(rhs)
    }

    /// Computes the tensor product (also known as the outer product) of two `CausalTensor`s.
    ///
    /// The tensor product combines two tensors into a new tensor whose rank is the sum of
    /// the ranks of the input tensors, and whose shape is the concatenation of their shapes.
    /// Each element of the resulting tensor is the product of an element from the left-hand side
    /// tensor and an element from the right-hand side tensor.
    ///
    /// This operation is fundamental in linear algebra and tensor calculus, effectively
    /// creating all possible pairwise products between elements of the input tensors.
    ///
    /// # Arguments
    ///
    /// * `rhs` - The right-hand side `CausalTensor`.
    ///
    /// # Returns
    ///
    /// A `Result` which is:
    /// - `Ok(CausalTensor<T>)` containing the result of the tensor product.
    /// - `Err(CausalTensorError)` if an error occurs during the operation (e.g., memory allocation).
    ///
    /// # Errors
    ///
    /// This method can return `CausalTensorError` if the underlying `tensor_product_impl`
    /// encounters an issue, such as a failure during new tensor creation.
    ///
    /// # Examples
    ///
    /// ```
    /// use deep_causality_tensor::{CausalTensor, Tensor};
    ///
    /// let lhs = CausalTensor::new(vec![1.0, 2.0], vec![2]).unwrap(); // Shape [2]
    /// let rhs = CausalTensor::new(vec![3.0, 4.0, 5.0], vec![3]).unwrap(); // Shape [3]
    ///
    /// // Expected result:
    /// // [[1*3, 1*4, 1*5],
    /// //  [2*3, 2*4, 2*5]]
    /// // which is [[3.0, 4.0, 5.0], [6.0, 8.0, 10.0]] with shape [2, 3]
    /// let result = lhs.tensor_product(&rhs).unwrap();
    ///
    /// assert_eq!(result.shape(), &[2, 3]);
    /// assert_eq!(result.as_slice(), &[3.0, 4.0, 5.0, 6.0, 8.0, 10.0]);
    ///
    /// // Tensor product with a scalar
    /// let scalar = CausalTensor::new(vec![10.0], vec![]).unwrap(); // Shape []
    /// let vector = CausalTensor::new(vec![1.0, 2.0], vec![2]).unwrap(); // Shape [2]
    /// let result_scalar_vec = scalar.tensor_product(&vector).unwrap();
    /// assert_eq!(result_scalar_vec.shape(), &[2]);
    /// assert_eq!(result_scalar_vec.as_slice(), &[10.0, 20.0]);
    /// ```
    fn tensor_product(&self, rhs: &CausalTensor<T>) -> Result<CausalTensor<T>, CausalTensorError>
    where
        T: Clone + Mul<Output = T>,
    {
        self.tensor_product_impl(rhs)
    }

    /// Computes the L2 Norm (Euclidean Norm) of the tensor.
    ///
    /// $$ ||A||_2 = \sqrt{ \sum |x_i|^2 } $$
    ///
    /// This effectively flattens the tensor and calculates the vector magnitude.
    /// Useful for checking convergence (e.g., is the Laplacian zero?).
    fn norm_l2(&self) -> T
    where
        T: RealField + Default + Zero + Sum + Copy,
    {
        self.norm_l2_impl()
    }

    /// Computes the Squared L2 Norm.
    ///
    /// $$ ||A||^2 = \sum |x_i|^2 $$
    ///
    /// Faster than `norm_l2` because it avoids the square root.
    /// Preferred for threshold checks (e.g. `if norm_sq < epsilon * epsilon`).
    fn norm_sq(&self) -> T
    where
        T: RealField + Default + Zero + Sum + Copy + Mul,
    {
        self.norm_sq_impl()
    }

    /// Sums the elements along one or more specified axes.
    ///
    /// The dimensions corresponding to the `axes` provided will be removed from the
    /// shape of the resulting tensor. If `axes` is empty, the sum of all elements
    /// in the tensor is returned as a 0-dimensional (scalar) tensor.
    ///
    /// # Type Parameters
    ///
    /// * `T`: Must implement `Add<T, Output = T>` for summation.
    ///
    /// # Arguments
    ///
    /// * `axes` - A slice of `usize` indicating the axes along which to sum. Axes are 0-indexed.
    ///
    /// # Returns
    ///
    /// A `Result` which is:
    /// - `Ok(Self)`: A new `CausalTensor` containing the sums.
    /// - `Err(CausalTensorError)`: If an invalid axis is specified.
    ///
    /// # Examples
    ///
    /// ```
    /// use deep_causality_tensor::{CausalTensor, Tensor};
    ///
    /// let tensor = CausalTensor::new(vec![1, 2, 3, 4, 5, 6], vec![2, 3]).unwrap();
    /// // Tensor:
    /// // [[1, 2, 3],
    /// //  [4, 5, 6]]
    ///
    /// // Sum along axis 0 (columns): [1+4, 2+5, 3+6] = [5, 7, 9]
    /// let sum_axis0 = tensor.sum_axes(&[0]).unwrap();
    /// assert_eq!(sum_axis0.shape(), &[3]);
    /// assert_eq!(sum_axis0.as_slice(), &[5, 7, 9]);
    ///
    /// // Sum along axis 1 (rows): [1+2+3, 4+5+6] = [6, 15]
    /// let sum_axis1 = tensor.sum_axes(&[1]).unwrap();
    /// assert_eq!(sum_axis1.shape(), &[2]);
    /// assert_eq!(sum_axis1.as_slice(), &[6, 15]);
    ///
    /// // Sum all elements: 1+2+3+4+5+6 = 21
    /// let sum_all = tensor.sum_axes(&[]).unwrap();
    /// assert_eq!(sum_all.shape(), &[]); // Scalar result with shape [] still has one element.
    /// assert_eq!(sum_all.as_slice(), &[21]);
    ///
    /// // Invalid axis
    /// let err = tensor.sum_axes(&[2]);
    /// assert!(err.is_err());
    /// ```
    fn sum_axes(&self, axes: &[usize]) -> Result<Self, CausalTensorError>
    where
        T: Clone + Default + PartialOrd,
        T: Add<T, Output = T>,
    {
        self.sum_axes_impl(axes)
    }
    /// Calculates the mean (average) of the elements along one or more specified axes.
    ///
    /// The dimensions corresponding to the `axes` provided will be removed from the
    /// shape of the resulting tensor. If `axes` is empty, the mean of all elements
    /// in the tensor is returned as a 0-dimensional (scalar) tensor.
    ///
    /// # Type Parameters
    ///
    /// * `T`: Must implement `Div<T, Output = T>` for division.
    /// * `T`: Must implement `From<u32>` to convert counts to the numeric type
    /// * `T`: Must implement `Add<T, Output = T>` for summation.
    ///
    /// # Arguments
    ///
    /// * `axes` - A slice of `usize` indicating the axes along which to calculate the mean. Axes are 0-indexed.
    ///
    /// # Returns
    ///
    /// A `Result` which is:
    /// - `Ok(Self)`: A new `CausalTensor` containing the means.
    /// - `Err(CausalTensorError)`: If an invalid axis is specified.
    ///
    /// # Examples
    ///
    /// ```
    /// use deep_causality_tensor::{CausalTensor, Tensor};
    ///
    /// let tensor = CausalTensor::new(vec![1.0, 2.0, 3.0, 4.0, 5.0, 6.0], vec![2, 3]).unwrap();
    /// // Tensor:
    /// // [[1.0, 2.0, 3.0],
    /// //  [4.0, 5.0, 6.0]]
    ///
    /// // Mean along axis 0 (columns): [(1+4)/2, (2+5)/2, (3+6)/2] = [2.5, 3.5, 4.5]
    /// let mean_axis0 = tensor.mean_axes(&[0]).unwrap();
    /// assert_eq!(mean_axis0.shape(), &[3]);
    /// assert_eq!(mean_axis0.as_slice(), &[2.5, 3.5, 4.5]);
    ///
    /// // Mean along axis 1 (rows): [(1+2+3)/3, (4+5+6)/3] = [2.0, 5.0]
    /// let mean_axis1 = tensor.mean_axes(&[1]).unwrap();
    /// assert_eq!(mean_axis1.shape(), &[2]);
    /// assert_eq!(mean_axis1.as_slice(), &[2.0, 5.0]);
    ///
    /// // Mean of all elements: (1+2+3+4+5+6)/6 = 3.5
    /// let mean_all = tensor.mean_axes(&[]).unwrap();
    /// assert_eq!(mean_all.shape(), &[]); // Scalar result
    /// assert_eq!(mean_all.as_slice(), &[3.5]);
    /// ```
    fn mean_axes(&self, axes: &[usize]) -> Result<Self, CausalTensorError>
    where
        T: Clone + Default + PartialOrd,
        T: Div<T, Output = T> + From<u32> + Add<T, Output = T>,
    {
        self.mean_axes_impl(axes)
    }
    /// Computes the indices that would sort a 1-dimensional tensor (vector).
    ///
    /// This method is only valid for tensors with `ndim() == 1`. It returns a vector
    /// of indices such that applying these indices to the original tensor would yield
    /// a sorted version of the tensor. The sorting is stable.
    ///
    /// # Returns
    ///
    /// A `Result` which is:
    /// - `Ok(Vec<usize>)`: A vector of indices that sort the tensor.
    /// - `Err(CausalTensorError)`: If the tensor is not 1-dimensional.
    ///
    /// # Examples
    ///
    /// ```
    /// use deep_causality_tensor::{CausalTensor, Tensor};
    ///
    /// let tensor = CausalTensor::new(vec![3, 1, 4, 1, 5, 9, 2, 6], vec![8]).unwrap();
    /// let sorted_indices = tensor.arg_sort().unwrap();
    /// assert_eq!(sorted_indices, vec![1, 3, 6, 0, 2, 4, 7, 5]);
    ///
    /// // Verify sorting
    /// let sorted_data: Vec<_> = sorted_indices.iter().map(|&i| tensor.as_slice()[i]).collect();
    /// assert_eq!(sorted_data, vec![1, 1, 2, 3, 4, 5, 6, 9]);
    ///
    /// // Attempting to sort a 2D tensor will result in an error
    /// let multi_dim_tensor = CausalTensor::new(vec![1, 2, 3, 4], vec![2, 2]).unwrap();
    /// assert!(multi_dim_tensor.arg_sort().is_err());
    /// ```
    fn arg_sort(&self) -> Result<Vec<usize>, CausalTensorError>
    where
        T: Clone + Default + PartialOrd,
    {
        self.arg_sort_impl()
    }
    /// Returns a new tensor with the same data but a different shape.
    ///
    /// This is a metadata-only operation; it creates a new `CausalTensor` with a cloned copy
    /// of the original flat data. The underlying data is *not* physically reordered or reallocated.
    /// Only the `shape` and `strides` are recomputed to reflect the new logical view.
    /// The total number of elements implied by the `new_shape` must be equal to the total number of
    /// elements in the original tensor (`self.len()`).
    ///
    /// # Arguments
    ///
    /// * `new_shape` - A slice representing the desired new shape.
    ///
    /// # Returns
    ///
    /// A `Result` which is:
    /// - `Ok(Self)`: A new `CausalTensor` with the updated shape.
    /// - `Err(CausalTensorError)`: If the `new_shape` is incompatible (e.g., total elements don't match).
    ///
    /// # Examples
    ///
    /// ```
    /// use deep_causality_tensor::{CausalTensor, Tensor};
    ///
    /// let tensor = CausalTensor::new(vec![1, 2, 3, 4, 5, 6], vec![2, 3]).unwrap();
    ///
    /// // Reshape to 3x2
    /// let reshaped = tensor.reshape(&[3, 2]).unwrap();
    /// assert_eq!(reshaped.shape(), &[3, 2]);
    /// assert_eq!(reshaped.as_slice(), &[1, 2, 3, 4, 5, 6]); // Data remains the same
    ///
    /// // Reshape to 1D vector
    /// let raveled = tensor.reshape(&[6]).unwrap();
    /// assert_eq!(raveled.shape(), &[6]);
    ///
    /// // Incompatible shape (total elements don't match)
    /// let err = tensor.reshape(&[2, 2]);
    /// assert!(err.is_err());
    /// ```
    fn reshape(&self, new_shape: &[usize]) -> Result<Self, CausalTensorError>
    where
        T: Clone,
    {
        self.reshape_impl(new_shape)
    }
    /// Flattens the tensor into a 1-dimensional tensor (vector).
    ///
    /// This is a metadata-only operation; it does not copy or reallocate the underlying data.
    /// The resulting tensor will have a shape of `[self.len()]`.
    ///
    /// # Examples
    ///
    /// ```
    /// use deep_causality_tensor::{CausalTensor, Tensor};
    ///
    /// let tensor = CausalTensor::new(vec![1, 2, 3, 4, 5, 6], vec![2, 3]).unwrap();
    /// let raveled_tensor = tensor.ravel();
    /// assert_eq!(raveled_tensor.shape(), &[6]);
    /// assert_eq!(raveled_tensor.as_slice(), &[1, 2, 3, 4, 5, 6]);
    /// ```
    fn ravel(self) -> Self
    where
        T: Clone,
    {
        self.ravel_impl()
    }
    /// Creates a new tensor representing a slice of the original tensor along a specified axis.
    ///
    /// This operation extracts a sub-tensor where one dimension has been fixed to a specific index.
    /// The rank (number of dimensions) of the resulting tensor will be one less than the original.
    ///
    /// **Note:** This is a data-copying operation. It creates a new `CausalTensor` with its
    /// own allocated data. A future optimization could provide a zero-copy, lifetime-bound view.
    ///
    /// # Arguments
    /// * `axis` - The axis to slice along (0-indexed).
    /// * `index` - The index at which to slice the axis.
    ///
    /// # Returns
    /// A `Result` containing the new, sliced `CausalTensor`, or a `CausalTensorError` if
    /// the axis or index is out of bounds.
    ///
    /// # Examples
    ///
    /// ```
    /// use deep_causality_tensor::{CausalTensor, Tensor};
    ///
    /// let tensor = CausalTensor::new(vec![1, 2, 3, 4, 5, 6], vec![2, 3]).unwrap();
    /// // Tensor:
    /// // [[1, 2, 3],
    /// //  [4, 5, 6]]
    ///
    /// // Slice along axis 0 at index 0 (first row)
    /// let slice_row0 = tensor.slice(0, 0).unwrap();
    /// assert_eq!(slice_row0.shape(), &[3]);
    /// assert_eq!(slice_row0.as_slice(), &[1, 2, 3]);
    ///
    /// // Slice along axis 0 at index 1 (second row)
    /// let slice_row1 = tensor.slice(0, 1).unwrap();
    /// assert_eq!(slice_row1.shape(), &[3]);
    /// assert_eq!(slice_row1.as_slice(), &[4, 5, 6]);
    ///
    /// // Slice along axis 1 at index 1 (second column)
    /// let slice_col1 = tensor.slice(1, 1).unwrap();
    /// assert_eq!(slice_col1.shape(), &[2]);
    /// assert_eq!(slice_col1.as_slice(), &[2, 5]);
    /// ```
    fn slice(&self, axis: usize, index: usize) -> Result<CausalTensor<T>, CausalTensorError>
    where
        T: Clone,
    {
        self.slice_impl(axis, index)
    }
    /// Permutes the axes of the tensor according to the given new order.
    ///
    /// This is a metadata-only operation; it creates a new `CausalTensor` with a cloned copy
    /// of the original flat data. The underlying data is *not* physically reordered or reallocated.
    /// Only the `shape` and `strides` are recomputed to reflect the new logical axis order.
    ///
    /// # Arguments
    ///
    /// * `axes` - A slice of `usize` representing the new order of axes.
    ///
    /// The length of the `axes` parameter must be equal to the number of dimensions of the tensor,
    /// and it must contain a permutation of `0..self.num_dim()`.
    ///
    /// # Returns
    ///
    /// A `Result` which is:
    /// - `Ok(Self)`: A new `CausalTensor` with permuted axes.
    /// - `Err(CausalTensorError)`: If the `axes` are invalid (e.g., wrong length, not a permutation).
    fn permute_axes(&self, axes: &[usize]) -> Result<Self, CausalTensorError>
    where
        T: Clone,
    {
        self.permute_axes_impl(axes)
    }
    /// Creates a new tensor that is cyclically shifted (rolled) so that the
    /// element at `flat_index` moves to position 0.
    ///
    /// This is essential for Comonadic `extend` operations, allowing a local
    /// physics function to always treat the "current" pixel/particle as the
    /// origin (index 0) of the coordinate system.
    ///
    /// # Arguments
    /// * `flat_index` - The flat index in the data vector that should become the new origin.
    ///
    /// # Returns
    /// A new `CausalTensor` with the same shape, but rotated data.
    ///
    /// # Physics Note
    /// This implements Periodic Boundary Conditions (Topology of a Torus).
    /// If you shift off the edge, you wrap around to the other side.
    fn shifted_view(&self, flat_index: usize) -> Self
    where
        T: Clone,
    {
        self.shifted_view_impl(flat_index)
    }

    /// Computes the inverse of a square matrix using Gaussian elimination (Gauss-Jordan method).
    ///
    /// For a square matrix $A$, its inverse $A^{-1}$ is a matrix such that when $A$ is multiplied
    /// by $A^{-1}$ (in either order), the result is the identity matrix $I$. That is,
    /// $A A^{-1} = A^{-1} A = I$.
    ///
    /// This method uses the Gauss-Jordan elimination technique by augmenting the input matrix `A`
    /// with an identity matrix $I$ to form $[A | I]$. Row operations are then performed to transform
    /// the left side ($A$) into the identity matrix, resulting in the inverse matrix on the right side:
    /// $[A | I] \rightarrow [I | A^{-1}]$. Partial pivoting is used to enhance numerical stability.
    ///
    /// # Usage
    ///
    /// Matrix inversion is fundamental for:
    /// - Solving systems of linear equations: If $Ax = b$, then $x = A^{-1}b$.
    /// - Inverting linear transformations.
    /// - Various applications in optimization and numerical analysis.
    ///
    /// # Constraints
    ///
    /// - The tensor must be a 2D square matrix (i.e., `num_dim() == 2` and `shape[0] == shape[1]`).
    /// - The matrix must be non-singular (invertible). A singular matrix does not have an inverse.
    ///
    /// # Returns
    ///
    /// A `Result` which is:
    /// - `Ok(Self)`: A new `CausalTensor` representing the inverse matrix.
    /// - `Err(CausalTensorError)`: If the tensor is not a square matrix, is not 2-dimensional,
    ///   or is singular.
    ///
    /// # Errors
    ///
    /// - `CausalTensorError::DimensionMismatch`: If the tensor is not 2-dimensional.
    /// - `CausalTensorError::ShapeMismatch`: If the tensor is not a square matrix.
    /// - `CausalTensorError::SingularMatrix`: If the matrix is singular and cannot be inverted.
    /// - `CausalTensorError::DivisionByZero`: If a pivot element is zero during elimination.
    fn inverse(&self) -> Result<Self, CausalTensorError>
    where
        T: Clone + RealField + Zero + One + Sum + PartialEq,
    {
        self.inverse_impl()
    }

    fn svd(&self) -> Result<(Self, Self, Self), CausalTensorError>
    where
        T: Clone + RealField + Zero + One + Sum + PartialEq,
    {
        self.svd_impl()
    }

    /// Computes the Cholesky decomposition of a symmetric, positive-definite matrix.
    ///
    /// For a symmetric, positive-definite matrix $A$, its Cholesky decomposition is
    /// $A = L L^T$, where $L$ is a lower triangular matrix with positive diagonal entries,
    /// and $L^T$ is its transpose.
    ///
    /// The algorithm proceeds by calculating elements of $L$ column by column:
    /// - Diagonal elements: $L_{ii} = \sqrt{A_{ii} - \sum_{k=0}^{i-1} L_{ik}^2}$
    /// - Off-diagonal elements: $L_{ji} = \frac{1}{L_{ii}} (A_{ji} - \sum_{k=0}^{i-1} L_{jk} L_{ik})$ for $j > i$
    ///
    /// # Usage
    ///
    /// Cholesky decomposition is a cornerstone in numerical linear algebra, used for:
    /// - Solving systems of linear equations more efficiently than general methods (e.g., Gaussian elimination)
    ///   when the matrix is symmetric positive-definite.
    /// - Efficiently solving Least Squares problems (as implemented in `solve_least_squares_cholsky_impl`).
    /// - Monte Carlo simulations to generate correlated random variables.
    /// - Kalman filtering and other state estimation problems.
    ///
    /// # Constraints
    ///
    /// - The input `CausalTensor` must represent a 2D square matrix.
    /// - The matrix must be symmetric and positive-definite. If it is not positive-definite,
    ///   the decomposition will fail (e.g., attempt to take the square root of a negative number,
    ///   or encounter a zero on the diagonal).
    ///
    /// # Returns
    ///
    /// A `Result` which is:
    /// - `Ok(Self)`: A new `CausalTensor` representing the lower triangular Cholesky factor $L$.
    /// - `Err(CausalTensorError)`: If input dimensions are invalid, or if the matrix is not
    ///   symmetric positive-definite.
    ///
    /// # Errors
    ///
    /// - `CausalTensorError::DimensionMismatch`: If the tensor is not 2-dimensional.
    /// - `CausalTensorError::ShapeMismatch`: If the tensor is not a square matrix.
    /// - `CausalTensorError::SingularMatrix`: If the matrix is not positive-definite (e.g., a diagonal
    ///   element becomes zero or negative during computation).
    fn cholesky_decomposition(&self) -> Result<Self, CausalTensorError>
    where
        T: Default + Clone + RealField + Zero + One + PartialEq,
    {
        self.cholesky_decomposition_impl()
    }

    /// Solves the Least Squares problem for $Ax = b$ using Cholesky decomposition.
    ///
    /// Given a system of linear equations $Ax = b$, where $A$ is an $m \times n$ design matrix
    /// and $b$ is an $m \times 1$ observation vector, this method finds the vector $x$ (parameters)
    /// that minimizes the squared Euclidean norm of the residual $||Ax - b||^2$.
    ///
    /// The solution $x$ is obtained by solving the normal equations: $A^T A x = A^T b$.
    /// Let $M = A^T A$ and $y = A^T b$. The normal equations become $Mx = y$.
    ///
    /// The process involves:
    /// 1. Computing $M = A^T A$ and $y = A^T b$.
    /// 2. Performing Cholesky decomposition on $M$: $M = L L^T$, where $L$ is a lower triangular matrix.
    /// 3. Solving $Lz = y$ for $z$ using forward substitution.
    /// 4. Solving $L^T x = z$ for $x$ using backward substitution.
    ///
    /// This method is numerically stable and efficient for well-conditioned systems.
    ///
    /// # Usage
    ///
    /// This solver is commonly used in:
    /// - Linear Regression analysis to find the best-fit parameters.
    /// - Data fitting and curve fitting.
    /// - Various optimization and statistical modeling problems.
    ///
    /// # Arguments
    ///
    /// * `a` - The design matrix $A$ (m x n `CausalTensor`).
    /// * `b` - The observation vector $b$ (m x 1 `CausalTensor`).
    ///
    /// # Constraints
    ///
    /// - The design matrix $A$ should have full column rank for a unique solution.
    /// - The matrix $A^T A$ must be symmetric and positive-definite for Cholesky decomposition to succeed.
    /// - The observation vector $b$ must be a column vector with a number of rows compatible with $A$.
    ///
    /// # Returns
    ///
    /// A `Result` which is:
    /// - `Ok(Self)`: A new `CausalTensor` representing the solution vector $x$ (n x 1).
    /// - `Err(CausalTensorError)`: If input dimensions are invalid, or if $A^T A$ is singular.
    ///
    /// # Errors
    ///
    /// - `CausalTensorError::DimensionMismatch`: If `a` or `b` are not 2-dimensional, or `b` is not a column vector.
    /// - `CausalTensorError::ShapeMismatch`: If `b`'s rows do not match `a`'s rows.
    /// - `CausalTensorError::SingularMatrix`: If the $A^T A$ matrix is singular, implying no unique solution.
    fn solve_least_squares_cholsky(
        a: &Self, // Design matrix (m x n)
        b: &Self, // Observation vector (m x 1)
    ) -> Result<Self, CausalTensorError>
    where
        T: Default + Clone + RealField + Zero + One + PartialEq,
    {
        Self::solve_least_squares_cholsky_impl(a, b)
    }

    fn stack(tensors: &[CausalTensor<T>], axis: usize) -> Result<CausalTensor<T>, CausalTensorError>
    where
        T: Clone + Default + PartialOrd + Add<Output = T> + Mul<Output = T>,
        Self: Sized,
    {
        Self::stack_impl(tensors, axis)
    }
}
