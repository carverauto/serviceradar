/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The DeepCausality Authors and Contributors. All Rights Reserved.
 */
pub mod tensor_broadcast;
/// Conjugate transpose (Hermitian adjoint) for 2-D tensors.
mod tensor_dagger;
/// Dense Hermitian eigendecomposition (cyclic Jacobi; complex Givens for complex scalars).
pub(crate) mod tensor_eigen;
pub mod tensor_ein_sum;
mod tensor_inverse;
/// Kronecker (tensor) product for 2-D tensors.
mod tensor_kronecker;
mod tensor_product;
/// Householder QR decomposition (tensor-network canonicalization primitive).
mod tensor_qr;
/// QTT (quantized tensor-train) reshape helpers.
mod tensor_qtt;
/// Defines tensor reduction operations (e.g., sum, mean).
mod tensor_reduction;
/// Defines tensor shape manipulation operations (e.g., reshape, ravel).
mod tensor_shape;
mod tensor_stack;
mod tensor_svd;
mod tensor_svd_decomp;
/// Robust truncated thin-SVD (tensor-network numerical foundation).
mod tensor_svd_truncated;
/// Defines tensor view operations (e.g., slicing).
mod tensor_view;
