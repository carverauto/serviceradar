/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::CausalMultiVector;
use core::ops::{AddAssign, Neg, SubAssign};
use deep_causality_algebra::Field;

impl<T> CausalMultiVector<T> {
    // Threshold for sparse algorithm (CPU-based)
    // Dim 6 = 64 components -> 4096 iterations (Dense is likely still faster than Allocator)
    // Dim 7 = 128 components -> 16,384 iterations (Sparse starts winning)
    pub(in crate::types::multivector) const SPARSE_THRESHOLD: usize = 6;

    // Threshold for GPU acceleration via Matrix Isomorphism
    // Below this, CPU is faster due to GPU dispatch overhead
    #[allow(dead_code)]
    pub(in crate::types::multivector) const GPU_DIMENSION_THRESHOLD: usize = 6;

    // --- OPTIMIZED FOR LOW DIMENSION (No Aux Allocations) ---
    #[inline(always)]
    pub(in crate::types::multivector) fn geometric_product_dense(
        &self,
        rhs: &Self,
        dim: usize,
    ) -> Self
    where
        T: Field + Copy + Clone + AddAssign + SubAssign + Neg<Output = T>,
    {
        let count = 1 << dim;
        let mut result_data = vec![T::zero(); count];

        for i in 0..count {
            if self.data[i].is_zero() {
                continue;
            }

            for j in 0..count {
                if rhs.data[j].is_zero() {
                    continue;
                }

                let (sign, result_idx) = Self::basis_product(i, j, &self.metric);

                if sign == 0 {
                    continue;
                }

                let val = self.data[i] * rhs.data[j];

                // BRANCHLESS OPTIMIZATION:
                // Instead of if/else, we multiply by the sign.
                let sign_multiplier = if sign > 0 { T::one() } else { -T::one() };

                // CPU executes this as a single Multiply-Add stream
                result_data[result_idx] += val * sign_multiplier;
            }
        }

        Self {
            data: result_data,
            metric: self.metric,
        }
    }

    // --- OPTIMIZED FOR HIGH DIMENSION (Sparsity & Caching) ---
    pub(in crate::types::multivector) fn geometric_product_sparse(
        &self,
        rhs: &Self,
        dim: usize,
    ) -> Self
    where
        T: Field + Copy + Clone + AddAssign + SubAssign + Neg<Output = T>,
    {
        let count = 1 << dim;
        let mut result_data = vec![T::zero(); count];

        // 1. Metric Caching
        let metric_cache: Vec<i8> = (0..dim).map(|k| self.metric.sign_of_sq(k) as i8).collect();

        // 2. Sparsity Scan
        // Collect indices to avoid iterating over zeros (which is 99% of Cl(10))
        let mut lhs_indices = Vec::with_capacity(self.data.len() / 4); // Heuristic cap
        for (i, val) in self.data.iter().enumerate() {
            if !val.is_zero() {
                lhs_indices.push(i);
            }
        }

        if lhs_indices.is_empty() {
            return Self {
                data: result_data,
                metric: self.metric,
            };
        }

        let mut rhs_indices = Vec::with_capacity(rhs.data.len() / 4);
        for (j, val) in rhs.data.iter().enumerate() {
            if !val.is_zero() {
                rhs_indices.push(j);
            }
        }

        if rhs_indices.is_empty() {
            return Self {
                data: result_data,
                metric: self.metric,
            };
        }

        // 3. Sparse Loop
        for &i in &lhs_indices {
            let lhs_val = self.data[i];

            for &j in &rhs_indices {
                let rhs_val = rhs.data[j];

                // Use cached helper
                let (sign, result_idx) = Self::basis_product_cached(i, j, dim, &metric_cache);

                if sign == 0 {
                    continue;
                }

                let val = lhs_val * rhs_val;

                if sign > 0 {
                    result_data[result_idx] += val;
                } else {
                    result_data[result_idx] -= val;
                }
            }
        }

        Self {
            data: result_data,
            metric: self.metric,
        }
    }

    /// Computes the outer product (wedge product) $A \wedge B$.
    ///
    /// The outer product of two multivectors of grades $r$ and $s$ is the grade $r+s$ part of their geometric product.
    /// $$ A \wedge B = \langle AB \rangle_{r+s} $$
    ///
    /// For basis blades $e_I$ and $e_J$, $e_I \wedge e_J$ is non-zero only if $I \cap J = \emptyset$.
    pub(in crate::types::multivector) fn outer_product_impl(&self, rhs: &Self) -> Self
    where
        T: Field + Copy + Clone + AddAssign + SubAssign,
    {
        if self.metric != rhs.metric {
            panic!("Metric mismatch");
        }

        let dim = self.metric.dimension();
        let count = 1 << dim;
        let mut result_data = vec![T::zero(); count];

        for i in 0..count {
            if self.data[i].is_zero() {
                continue;
            }
            for j in 0..count {
                if rhs.data[j].is_zero() {
                    continue;
                }

                // Outer product is non-zero only if blades are disjoint
                if (i & j) == 0 {
                    // Calculate sign from swaps only, not the full geometric product.
                    let mut swaps = 0;
                    for k in 0..dim {
                        if (j >> k) & 1 == 1 {
                            swaps += (i >> (k + 1)).count_ones();
                        }
                    }
                    let sign = if swaps % 2 == 0 { 1 } else { -1 };

                    let result_idx = i | j; // For disjoint sets, XOR is equivalent to OR
                    let val = self.data[i] * rhs.data[j];

                    if sign > 0 {
                        result_data[result_idx] += val;
                    } else {
                        result_data[result_idx] -= val;
                    }
                }
            }
        }
        Self {
            data: result_data,
            metric: self.metric,
        }
    }
    /// Computes the inner product (left contraction) $A \cdot B$ (or $A \rfloor B$).
    ///
    /// The inner product of a grade $r$ multivector $A$ and a grade $s$ multivector $B$ is the grade $s-r$ part of their geometric product.
    /// $$ A \cdot B = \langle AB \rangle_{s-r} $$
    ///
    /// For basis blades $e_I$ and $e_J$, $e_I \cdot e_J$ is non-zero only if $I \subseteq J$.
    pub(in crate::types::multivector) fn inner_product_impl(&self, rhs: &Self) -> Self
    where
        T: Field + Copy + Clone + AddAssign + SubAssign,
    {
        if self.metric != rhs.metric {
            panic!("Metric mismatch");
        }

        let dim = self.metric.dimension();
        let count = 1 << dim;
        let mut result_data = vec![T::zero(); count];

        for i in 0..count {
            if self.data[i].is_zero() {
                continue;
            }
            for j in 0..count {
                if rhs.data[j].is_zero() {
                    continue;
                }

                // Left contraction requires I subset J
                if (i & j) == i {
                    let (sign, result_idx) = Self::basis_product(i, j, &self.metric);

                    if sign != 0 {
                        let val = self.data[i] * rhs.data[j];
                        if sign > 0 {
                            result_data[result_idx] += val;
                        } else {
                            result_data[result_idx] -= val;
                        }
                    }
                }
            }
        }
        Self {
            data: result_data,
            metric: self.metric,
        }
    }

    pub(in crate::types::multivector) fn commutator_lie_impl(&self, rhs: &Self) -> Self
    where
        T: Field + Copy + Clone + AddAssign + SubAssign + Neg<Output = T>,
    {
        if self.metric != rhs.metric {
            panic!("Metric mismatch");
        }

        let dim = self.metric.dimension();
        let count = 1 << dim;
        let mut result_data = vec![T::zero(); count];

        for i in 0..count {
            if self.data[i].is_zero() {
                continue;
            }
            for j in 0..count {
                if rhs.data[j].is_zero() {
                    continue;
                }

                // 1. Calculate Directions
                let (sign_ab, k) = Self::basis_product(i, j, &self.metric);
                if sign_ab == 0 {
                    continue;
                } // Handle degenerate metric

                let (sign_ba, _) = Self::basis_product(j, i, &self.metric);

                // 2. [A, B] = AB - BA
                // If signs differ, we have non-zero commutator
                if sign_ab != sign_ba {
                    let val = self.data[i] * rhs.data[j];

                    // Result is 2 * sign_ab * val
                    // We use (val + val) to double it efficiently
                    let double_val = val + val;

                    if sign_ab > 0 {
                        result_data[k] += double_val;
                    } else {
                        result_data[k] -= double_val;
                    }
                }
            }
        }

        Self {
            data: result_data,
            metric: self.metric,
        }
    }

    // The scaled logic 0.5 * (AB - BA)
    pub(in crate::types::multivector) fn commutator_geometric_impl(&self, rhs: &Self) -> Self
    where
        T: Field
            + Copy
            + Clone
            + AddAssign
            + SubAssign
            + Neg<Output = T>
            + core::ops::Div<Output = T>,
    {
        // 1. Calculate the raw Lie bracket (AB - BA)
        let lie_bracket = self.commutator_lie_impl(rhs);

        // 2. Define "2" using the generic One trait
        // This works for f64 (1.0+1.0=2.0), Complex (1+i0 + 1+i0 = 2+i0), etc.
        let two = T::one() + T::one();

        // 3. Check for division by zero (e.g. in Boolean algebra 1+1=0, or GF(2))
        if two.is_zero() {
            // In a field where 1+1=0 (Characteristic 2), division by 2 is undefined.
            // For Physics (R/C), this branch is never taken.
            // You might panic or return the Lie bracket depending on philosophy.
            panic!(
                "Cannot compute Geometric Commutator (scale by 1/2) in a field with characteristic 2"
            );
        }

        // 4. Scale the result
        let scaled_data = lie_bracket.data.into_iter().map(|val| val / two).collect();

        Self {
            data: scaled_data,
            metric: lie_bracket.metric,
        }
    }

    pub(in crate::types::multivector) fn geometric_product_impl(&self, rhs: &Self) -> Self
    where
        T: Field + Copy + Clone + AddAssign + SubAssign + Neg<Output = T>,
    {
        if self.metric != rhs.metric {
            panic!(
                "Geometric Product Metric mismatch: {:?} vs {:?}",
                self.metric, rhs.metric
            );
        }

        let dim = self.metric.dimension();

        // CPU dispatch based on dimension threshold
        if dim <= Self::SPARSE_THRESHOLD {
            self.geometric_product_dense(rhs, dim)
        } else {
            self.geometric_product_sparse(rhs, dim)
        }
    }
}
