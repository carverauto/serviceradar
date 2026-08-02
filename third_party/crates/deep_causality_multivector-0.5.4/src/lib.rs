/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

mod alias;
mod errors;
mod extensions;
mod traits;
mod types;

// Aliases
pub use crate::alias::{
    ComplexMultiVector, DixonAlgebra, HilbertState, HopfState, KET_COLUMN, PGA3DMultiVector,
    RealMultiVector,
};

// Errors
pub use crate::errors::causal_multivector_error::CausalMultiVectorError;

// Extensions
pub use crate::extensions::hkt_multifield::CausalMultiFieldWitness;
pub use crate::extensions::hkt_multivector::CausalMultiVectorWitness;
pub use crate::extensions::iso_multifield::MultiFieldCarrier;

// Traits
pub use crate::traits::l2_norm::MultiVectorL2Norm;
pub use crate::traits::multi_vector::MultiVector;
pub use crate::traits::scalar_eval::ScalarEval;
pub use crate::types::multifield::ops::batched_matmul::BatchedMatMul;

// Types
pub use crate::types::multifield::CausalMultiField;
pub use crate::types::multifield::ops::differential::Axis;
pub use crate::types::multivector::CausalMultiVector;
pub use deep_causality_metric::Metric;
pub use types::multifield::ops::gamma::{
    compute_gamma_element, get_basis_gammas, get_dual_basis_gammas, get_gammas, matrix_dim,
    num_blades,
};

// Tensor re-export for convenience
pub use deep_causality_tensor::CausalTensor;
