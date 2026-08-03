/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{CausalMultiVector, Metric};

impl<T> CausalMultiVector<T> {
    /// Helper function to calculate the sign and index of the geometric product of two basis blades.
    ///
    /// Given two basis blades $e_A$ and $e_B$ (represented by bitmaps `a_map` and `b_map`),
    /// this function computes the resulting basis blade $e_C$ (bitmap `result_map`) and the sign $s$ such that:
    /// $$ e_A e_B = s e_C $$
    ///
    /// The sign accounts for:
    /// 1. Canonical reordering (swaps).
    /// 2. Metric signature (squaring of basis vectors).
    ///
    /// If any basis vector in the intersection squares to 0 (degenerate metric), the result is 0.
    pub(super) fn basis_product(a_map: usize, b_map: usize, metric: &Metric) -> (i32, usize) {
        let mut sign = 1;

        // 1. Count Swaps (Canonical Reordering)
        // How many active bits in A are strictly greater than active bits in B?
        let mut swaps = 0;
        let dim = metric.dimension();

        // Iterate through bits of B
        for i in 0..dim {
            if (b_map >> i) & 1 == 1 {
                // Count bits in A that are higher than i
                let higher_in_a = (a_map >> (i + 1)).count_ones();
                swaps += higher_in_a;
            }
        }

        if (swaps % 2) != 0 {
            sign = -1;
        }

        // 2. Handle Metric Squaring
        // Bits present in BOTH A and B are the ones being squared (e_i * e_i)
        let overlap = a_map & b_map;
        for i in 0..dim {
            if (overlap >> i) & 1 == 1 {
                let s = metric.sign_of_sq(i);
                if s == 0 {
                    return (0, 0);
                } // Degenerate metric -> 0
                sign *= s;
            }
        }

        // 3. Result Index is XOR
        (sign, a_map ^ b_map)
    }

    /// An optimized version of basis_product that uses a pre-computed metric cache
    /// to avoid repeated Enum matching / branching inside the hot loop.
    #[inline(always)]
    pub(super) fn basis_product_cached(
        a_map: usize,
        b_map: usize,
        _dim: usize,
        metric_signs: &[i8],
    ) -> (i8, usize) {
        let mut sign: i8 = 1;

        // 1. Canonical Reordering (Swaps)
        // Optimization: We can iterate only the bits of B.
        // Ideally this would use popcount intrinsics, but loop is robust.
        let mut b_temp = b_map;
        let mut bit_idx = 0;

        while b_temp > 0 {
            if (b_temp & 1) == 1 {
                // If bit k is set in B, count how many bits in A are HIGHER than k.
                // (a_map >> (bit_idx + 1)) removes bits <= k.
                let higher_bits = (a_map >> (bit_idx + 1)).count_ones();
                if !higher_bits.is_multiple_of(2) {
                    sign = -sign;
                }
            }
            b_temp >>= 1;
            bit_idx += 1;
        }

        // 2. Metric Squaring
        // Bits present in BOTH are squared.
        let mut overlap = a_map & b_map;
        let mut bit_idx = 0;

        while overlap > 0 {
            if (overlap & 1) == 1 {
                let s = metric_signs[bit_idx];
                if s == 0 {
                    return (0, 0);
                } // Degenerate
                if s < 0 {
                    sign = -sign;
                }
            }
            overlap >>= 1;
            bit_idx += 1;
        }

        (sign, a_map ^ b_map)
    }
}
#[cfg(test)]
mod tests;
