/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{CausalTensor, CausalTensorError};
use deep_causality_algebra::RealField;
use std::iter::Sum;
use std::ops::Neg;

impl<T> CausalTensor<T>
where
    T: RealField + Sum + Neg<Output = T>,
{
    pub(crate) fn svd_impl(&self) -> Result<(Self, Self, Self), CausalTensorError> {
        if self.shape.len() != 2 {
            return Err(CausalTensorError::DimensionMismatch);
        }

        let m = self.shape()[0]; // rows
        let n = self.shape()[1]; // cols
        let k = m.min(n); // number of singular values

        // Copy A for deflation
        let mut a_data: Vec<T> = self.as_slice().to_vec();

        // Output arrays
        let mut u_data: Vec<T> = vec![T::zero(); m * k];
        let mut s_data: Vec<T> = vec![T::zero(); k];
        let mut vt_data: Vec<T> = vec![T::zero(); k * n];

        let max_iterations = 100;
        // Tolerance: use a small fraction (1/1000000 ≈ 1e-6)
        let mut tolerance = T::one();
        for _ in 0..6 {
            tolerance /= T::one()
                + T::one()
                + T::one()
                + T::one()
                + T::one()
                + T::one()
                + T::one()
                + T::one()
                + T::one()
                + T::one(); // divide by 10
        }

        // Helper functions for row-major access
        let get_a = |data: &[T], row: usize, col: usize| data[row * n + col];
        let set_a = |data: &mut [T], row: usize, col: usize, val: T| {
            data[row * n + col] = val;
        };

        // Find each singular triplet via power iteration
        for i in 0..k {
            // Initialize v vector with values based on index (deterministic pattern)
            let mut v: Vec<T> = (0..n)
                .map(|j| {
                    let mut val = T::one();
                    // Scale by (j+1)/(n+1) approximately
                    for _ in 0..(j + i + 1) {
                        val += T::one() / (T::one() + T::one());
                    }
                    val / (T::one() + T::one() + T::one()) // normalize roughly
                })
                .collect();

            // Normalize v
            let v_norm: T = v.iter().map(|&x| x * x).sum::<T>().sqrt();
            if v_norm > T::zero() {
                for x in &mut v {
                    *x /= v_norm;
                }
            }

            let mut sigma = T::zero();

            // Power iteration
            for _iter in 0..max_iterations {
                // u = A * v
                let mut u: Vec<T> = vec![T::zero(); m];
                for (row, u_row) in u.iter_mut().enumerate() {
                    for (col, v_col) in v.iter().enumerate() {
                        *u_row += get_a(&a_data, row, col) * *v_col;
                    }
                }

                // sigma = ||u||
                let new_sigma: T = u.iter().map(|&x| x * x).sum::<T>().sqrt();

                if new_sigma == T::zero() {
                    break;
                }

                // Normalize u
                for x in &mut u {
                    *x /= new_sigma;
                }

                // v = A^T * u
                let mut new_v: Vec<T> = vec![T::zero(); n];
                for (col, new_v_col) in new_v.iter_mut().enumerate() {
                    for (row, u_row) in u.iter().enumerate() {
                        *new_v_col += get_a(&a_data, row, col) * *u_row;
                    }
                }

                // Normalize v
                let v_norm: T = new_v.iter().map(|&x| x * x).sum::<T>().sqrt();
                if v_norm > T::zero() {
                    for x in &mut new_v {
                        *x /= v_norm;
                    }
                }

                // Check convergence
                let diff: T = (new_sigma - sigma).abs();
                sigma = new_sigma;
                v = new_v;

                if diff < tolerance * sigma {
                    break;
                }
            }

            // Store results
            s_data[i] = sigma;

            // Store u column
            // Recompute u from final v
            let mut u: Vec<T> = vec![T::zero(); m];
            for (row, u_row) in u.iter_mut().enumerate() {
                for (col, v_col) in v.iter().enumerate() {
                    *u_row += get_a(&a_data, row, col) * *v_col;
                }
            }
            let u_norm: T = u.iter().map(|&x| x * x).sum::<T>().sqrt();
            if u_norm > T::zero() {
                for x in &mut u {
                    *x /= u_norm;
                }
            }

            for row in 0..m {
                u_data[row * k + i] = u[row];
            }

            // Store v^T row
            for col in 0..n {
                vt_data[i * n + col] = v[col];
            }

            // Deflate: A = A - sigma * u * v^T
            for (row, u_row) in u.iter().enumerate() {
                for (col, v_col) in v.iter().enumerate() {
                    let old = get_a(&a_data, row, col);
                    set_a(&mut a_data, row, col, old - sigma * *u_row * *v_col);
                }
            }
        }

        let u = CausalTensor::new(u_data, vec![m, k])?;
        let s = CausalTensor::new(s_data, vec![k])?;
        let vt = CausalTensor::new(vt_data, vec![k, n])?;

        Ok((u, s, vt))
    }
}
