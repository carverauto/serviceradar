/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

mod errors;
mod extensions;
mod solver;
mod types;

// Solvers
pub use crate::solver::cg::{
    CgFailure, cg_solve, cg_solve_preconditioned, cg_solve_preconditioned_from,
};

// Sparse type
pub use crate::errors::SparseMatrixError;
pub use crate::extensions::ext_hkt::CsrMatrixWitness;
#[cfg(feature = "tensor-iso")]
pub use crate::extensions::ext_iso::CsrFromTensorError;
pub use crate::types::sparse_matrix::CsrMatrix;
