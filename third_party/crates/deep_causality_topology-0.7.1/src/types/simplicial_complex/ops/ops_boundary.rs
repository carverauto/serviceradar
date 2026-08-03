/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{Chain, SimplicialComplex};
use core::fmt::Debug;
use deep_causality_num::Num;
use deep_causality_sparse::CsrMatrix;

impl<T> SimplicialComplex<T> {
    /// Computes the boundary of a chain: ∂c
    /// Maps a k-chain to a (k-1)-chain.
    pub fn boundary(&self, chain: &Chain<T>) -> Chain<T>
    where
        T: Copy + Num + Default + From<i8> + Debug,
    {
        if chain.grade == 0 {
            panic!("Cannot take boundary of 0-chain");
        }

        // This is N_{k-1} x N_k
        let boundary_op = &self.boundary_operators[chain.grade - 1];
        let k_minus_1_size = self.skeletons[chain.grade - 1].simplices.len();
        let mut new_triplets = Vec::new();

        // Manual mat-vec mul: v_out = M * v_in
        // Iterate over rows of M (simplices in k-1 skeleton)
        for r in 0..boundary_op.shape().0 {
            let mut val = T::zero();
            // Iterate over non-zero elements in this row of M
            let row_start = boundary_op.row_indices()[r];
            let row_end = boundary_op.row_indices()[r + 1];

            for i in row_start..row_end {
                let c = boundary_op.col_indices()[i]; // This is a simplex in k skeleton
                let m_val = T::from(boundary_op.values()[i]);

                // Find corresponding value in input chain vector (which is a single-row sparse matrix)
                let chain_row_start = chain.weights.row_indices()[0];
                let chain_row_end = chain.weights.row_indices()[1];
                for j in chain_row_start..chain_row_end {
                    if chain.weights.col_indices()[j] == c {
                        let v_val = &chain.weights.values()[j];
                        val = val + (m_val * *v_val);
                        break; // Found the column, move to next element in M's row
                    }
                }
            }

            if val != T::zero() {
                new_triplets.push((0, r, val));
            }
        }

        let new_weights = CsrMatrix::from_triplets(1, k_minus_1_size, &new_triplets).unwrap();

        Chain {
            complex: chain.complex.clone(),
            grade: chain.grade - 1,
            weights: new_weights,
        }
    }

    /// Computes the coboundary (exterior derivative) of a cochain: dω
    /// Maps a k-cochain to a (k+1)-cochain.
    pub fn coboundary(&self, chain: &Chain<T>) -> Chain<T>
    where
        T: Copy + Num + Default + From<i8>,
    {
        if chain.grade >= self.skeletons.len() - 1 {
            panic!("Cannot take coboundary of max-dim chain");
        }

        let coboundary_op = &self.coboundary_operators[chain.grade]; // This is N_{k+1} x N_k
        let k_plus_1_size = self.skeletons[chain.grade + 1].simplices.len();

        let mut new_triplets = Vec::new();

        // Manual mat-vec mul
        for r in 0..coboundary_op.shape().0 {
            let mut val = T::zero();
            let row_start = coboundary_op.row_indices()[r];
            let row_end = coboundary_op.row_indices()[r + 1];

            for i in row_start..row_end {
                let c = coboundary_op.col_indices()[i];
                let m_val = T::from(coboundary_op.values()[i]);

                // Find corresponding value in input chain vector
                let chain_row_start = chain.weights.row_indices()[0];
                let chain_row_end = chain.weights.row_indices()[1];
                for j in chain_row_start..chain_row_end {
                    if chain.weights.col_indices()[j] == c {
                        let v_val = &chain.weights.values()[j];
                        val = val + (m_val * *v_val);
                        break;
                    }
                }
            }

            if val != T::zero() {
                new_triplets.push((0, r, val));
            }
        }

        let new_weights = CsrMatrix::from_triplets(1, k_plus_1_size, &new_triplets).unwrap();

        Chain {
            complex: chain.complex.clone(),
            grade: chain.grade + 1,
            weights: new_weights,
        }
    }
}
