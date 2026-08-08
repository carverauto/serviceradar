/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::traits::cell::Cell;
use crate::traits::chain_complex::ChainComplex;
use crate::types::cell_complex::CellComplex;
use deep_causality_sparse::CsrMatrix;
use std::collections::HashMap;
use std::sync::Arc;

/// The boundary operator ∂: C_k → C_{k-1} for a cell complex.
///
/// This struct encapsulates the sparse matrix of the boundary operator
/// and provides methods to apply it to chains (linear combinations of cells).
/// Chains are represented as Vec<(Cell, i8)>.
pub struct BoundaryOperator<C: Cell> {
    matrix: CsrMatrix<i8>,
    complex: Arc<CellComplex<C>>,
    k: usize,
}

impl<C: Cell> BoundaryOperator<C> {
    pub fn new(complex: Arc<CellComplex<C>>, k: usize) -> Self {
        let matrix = complex.boundary_matrix(k).into_owned();
        Self { matrix, complex, k }
    }

    pub fn matrix(&self) -> &CsrMatrix<i8> {
        &self.matrix
    }

    pub fn source_dim(&self) -> usize {
        self.k
    }

    pub fn target_dim(&self) -> usize {
        if self.k > 0 { self.k - 1 } else { 0 }
    }

    /// Apply ∂ to a k-chain.
    pub fn apply(&self, chain: &[(C, i8)]) -> Vec<(C, i8)> {
        // Map input cells to vector indices
        let input_size = self.complex.num_cells(self.k);
        let mut input_vec = vec![0i8; input_size];

        let cells = self.complex.cells_vec(self.k);
        let mut idx_map = HashMap::with_capacity(input_size);
        for (i, c) in cells.iter().enumerate() {
            idx_map.insert(c, i);
        }

        for (cell, coeff) in chain {
            if let Some(&idx) = idx_map.get(cell) {
                input_vec[idx] = *coeff;
            }
        }

        // Matrix vector multiplication: y = M x
        // M is (target_dim x source_dim) i.e. (rows x cols)
        let output_size = self.complex.num_cells(self.target_dim());
        let mut output_vec = vec![0i8; output_size];

        let row_indices = self.matrix.row_indices();
        let col_indices = self.matrix.col_indices();
        let values = self.matrix.values();

        // Iterate rows
        for r in 0..self.matrix.shape().0 {
            if r >= output_vec.len() {
                break;
            }
            let start = row_indices[r];
            let end = row_indices[r + 1];

            let mut sum = 0i8;
            for idx in start..end {
                let c = col_indices[idx];
                let v = values[idx];
                if c < input_vec.len() {
                    sum += v * input_vec[c];
                }
            }
            output_vec[r] = sum;
        }

        // Convert back to chain
        let mut result_chain = Vec::new();
        let target_cells = self.complex.cells_vec(self.target_dim());

        for (i, &val) in output_vec.iter().enumerate() {
            if val != 0 && i < target_cells.len() {
                result_chain.push((target_cells[i].clone(), val));
            }
        }

        result_chain
    }
}
