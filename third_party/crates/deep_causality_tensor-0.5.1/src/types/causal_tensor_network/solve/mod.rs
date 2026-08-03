/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Tensor-train solvers sharing one alternating single-site sweep engine:
//! - `fit` — TT completion / regression from samples (block-diagonal local least squares).
//! - `linear` — `A x = b` in tensor-train form via AMEn (rank-adaptive residual enrichment).
//! - `eigen` — lowest eigenpair of a symmetric operator via DMRG3S (single-site DMRG with
//!   subspace expansion).
//! - `tdvp_step` — one two-site TDVP2 time step `dx/dt = op·x` (rank-adaptive, norm-conserving for
//!   a skew-symmetric generator).

mod local;

pub use local::{eigen, fit, linear, tdvp_step};
