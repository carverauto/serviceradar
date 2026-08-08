/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::SimplicialComplex;
use core::fmt::Debug;
use deep_causality_sparse::CsrMatrix;
use std::sync::Arc;

mod algebra;
mod arithmetic;
mod display;

/// Represents a weighted collection of simplices.
/// (e.g., A path is a `Chain<f64>` on the 1-skeleton where weights are 1.0).
#[derive(Debug, Clone, PartialEq)]
pub struct Chain<T> {
    pub(crate) complex: Arc<SimplicialComplex<T>>,
    pub(crate) grade: usize,
    /// Sparse vector of active simplices.
    /// Reuses CsrMatrix logic (1 row, N cols) for efficient sparse operations.
    pub(crate) weights: CsrMatrix<T>,
}

impl<T> Chain<T> {
    pub fn new(complex: Arc<SimplicialComplex<T>>, grade: usize, weights: CsrMatrix<T>) -> Self {
        Self {
            complex,
            grade,
            weights,
        }
    }
}

impl<T> Chain<T> {
    pub fn complex(&self) -> &Arc<SimplicialComplex<T>> {
        &self.complex
    }

    pub fn grade(&self) -> usize {
        self.grade
    }

    pub fn weights(&self) -> &CsrMatrix<T> {
        &self.weights
    }
}
