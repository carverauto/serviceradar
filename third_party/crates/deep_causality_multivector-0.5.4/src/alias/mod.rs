/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
mod alias_complex;
mod alias_hilbert_state;
mod alias_hopf_state;
mod alias_pga3d;
mod alias_real;

use crate::CausalMultiVector;
use deep_causality_num_complex::Complex64;

pub type ComplexMultiVector = CausalMultiVector<Complex64>;

pub type DixonAlgebra = CausalMultiVector<Complex64>;

pub type PGA3DMultiVector = CausalMultiVector<f64>;

pub type RealMultiVector = CausalMultiVector<f64>;

pub use alias_hilbert_state::{HilbertState, KET_COLUMN};
pub use alias_hopf_state::HopfState;
