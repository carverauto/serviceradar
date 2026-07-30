/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

#[cfg(feature = "alloc")]
use alloc::vec::Vec;

use crate::errors::MetricError;

mod display;
mod hash;

/// Defines the metric signature of the Clifford Algebra Cl(p, q, r).
///
/// The metric determines the squaring behavior of the basis vectors $e_i$:
/// * $e_i^2 = +1$ (positive, timelike in West Coast)
/// * $e_i^2 = -1$ (negative, timelike in East Coast)
/// * $e_i^2 = 0$ (degenerate, null)
///
/// The dimension $N = p + q + r$ is the total number of basis vectors.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Metric {
    /// All basis vectors square to +1.
    /// Signature: (N, 0, 0)
    Euclidean(usize),

    /// All basis vectors square to -1.
    /// Signature: (0, N, 0)
    NonEuclidean(usize),

    /// West Coast Minkowski: e₀² = +1, others = -1.
    /// Signature: (1, N-1, 0)
    /// Also known as: Weinberg, Particle Physics, "mostly minus"
    Minkowski(usize),

    /// East Coast Lorentzian: e₀² = -1, others = +1.
    /// Signature: (N-1, 1, 0)
    /// Also known as: GR, "mostly plus"
    Lorentzian(usize),

    /// Projective Geometric Algebra (PGA).
    /// Convention: e₀² = 0 (degenerate), others +1.
    /// Signature: (N-1, 0, 1) where the *first* vector is the zero vector.
    PGA(usize),

    /// Explicit generic signature Cl(p, q, r).
    /// Order of generators assumed:
    /// First p are (+), next q are (-), last r are (0).
    Generic { p: usize, q: usize, r: usize },

    /// Fully arbitrary signature defined by bitmasks.
    /// dim: Total dimension
    /// neg_mask: bit is 1 if e_i² = -1
    /// zero_mask: bit is 1 if e_i² = 0
    /// (If both bits are 0, default is +1)
    Custom {
        dim: usize,
        neg_mask: u64,
        zero_mask: u64,
    },
}

impl Metric {
    /// Returns the total dimension of the vector space (N = p + q + r)
    pub fn dimension(&self) -> usize {
        match self {
            Metric::Euclidean(d)
            | Metric::NonEuclidean(d)
            | Metric::Minkowski(d)
            | Metric::Lorentzian(d)
            | Metric::PGA(d) => *d,
            Metric::Generic { p, q, r } => p + q + r,
            Metric::Custom { dim, .. } => *dim,
        }
    }

    /// Returns the value of the basis vector squared: $e_i^2$.
    /// Possible return values: 1, -1, or 0.
    ///
    /// # Arguments
    /// * `i` - The 0-indexed generator index (0..N-1).
    pub fn sign_of_sq(&self, i: usize) -> i32 {
        match self {
            Metric::Euclidean(_) => 1,

            Metric::NonEuclidean(_) => -1,

            // Minkowski (West Coast): e0 is Time (+), e1..eN are Space (-)
            Metric::Minkowski(_) => {
                if i == 0 {
                    1
                } else {
                    -1
                }
            }

            // Lorentzian (East Coast): e0 is Time (-), e1..eN are Space (+)
            Metric::Lorentzian(_) => {
                if i == 0 {
                    -1
                } else {
                    1
                }
            }

            // PGA: e0 is Origin/Horizon (0), e1..eN are Euclidean (+)
            Metric::PGA(_) => {
                if i == 0 {
                    0
                } else {
                    1
                }
            }

            Metric::Generic { p, q, r: _ } => {
                if i < *p {
                    1
                } else if i < p + *q {
                    -1
                } else {
                    0 // The last r dimensions are degenerate
                }
            }

            Metric::Custom {
                dim: _,
                neg_mask,
                zero_mask,
            } => {
                let is_zero = (zero_mask >> i) & 1 == 1;
                if is_zero {
                    return 0;
                }

                let is_neg = (neg_mask >> i) & 1 == 1;
                if is_neg {
                    return -1;
                }

                1 // Default to positive
            }
        }
    }

    /// Returns the signature tuple (p, q, r) where:
    /// - p: number of +1 eigenvalues
    /// - q: number of -1 eigenvalues
    /// - r: number of 0 eigenvalues (degenerate)
    pub fn signature(&self) -> (usize, usize, usize) {
        match self {
            Metric::Euclidean(n) => (*n, 0, 0),
            Metric::NonEuclidean(n) => (0, *n, 0),
            Metric::Minkowski(n) => (1, n.saturating_sub(1), 0),
            Metric::Lorentzian(n) => (n.saturating_sub(1), 1, 0),
            Metric::PGA(n) => (n.saturating_sub(1), 0, 1),
            Metric::Generic { p, q, r } => (*p, *q, *r),
            Metric::Custom {
                dim,
                neg_mask,
                zero_mask,
            } => {
                let mut p = 0usize;
                let mut q = 0usize;
                let mut r = 0usize;
                for i in 0..*dim {
                    if (zero_mask >> i) & 1 == 1 {
                        r += 1;
                    } else if (neg_mask >> i) & 1 == 1 {
                        q += 1;
                    } else {
                        p += 1;
                    }
                }
                (p, q, r)
            }
        }
    }

    /// Flip time and space signs (convert between East Coast and West Coast conventions).
    ///
    /// This swaps +1 ↔ -1 for all basis vectors while preserving degenerate (0) vectors.
    /// Minkowski(n) becomes Custom with East Coast convention (-+++...).
    pub fn flip_time_space(&self) -> Self {
        let dim = self.dimension();
        if dim > 64 {
            // Cannot represent in bitmask, return Generic
            let (p, q, r) = self.signature();
            return Metric::Generic { p: q, q: p, r };
        }

        let mut neg_mask = 0u64;
        let mut zero_mask = 0u64;

        for i in 0..dim {
            match self.sign_of_sq(i) {
                1 => neg_mask |= 1 << i,  // +1 becomes -1
                -1 => {}                  // -1 becomes +1 (default)
                0 => zero_mask |= 1 << i, // 0 stays 0
                _ => {}
            }
        }

        Metric::Custom {
            dim,
            neg_mask,
            zero_mask,
        }
    }

    /// Merges two metrics during a Tensor Product (Monad bind).
    /// e.g., Euclidean(2) + Euclidean(2) -> Euclidean(4)
    pub fn tensor_product(&self, other: &Self) -> Self {
        use Metric::*;
        let dim_a = self.dimension();
        let dim_b = other.dimension();

        match (self, other) {
            (Euclidean(a), Euclidean(b)) => Euclidean(a + b),
            (NonEuclidean(a), NonEuclidean(b)) => NonEuclidean(a + b),
            // For any other combination, construct a generic metric.
            _ => {
                let mut p = 0;
                let mut q = 0;
                let mut r = 0;

                for i in 0..dim_a {
                    match self.sign_of_sq(i) {
                        1 => p += 1,
                        -1 => q += 1,
                        0 => r += 1,
                        _ => {}
                    }
                }
                for i in 0..dim_b {
                    match other.sign_of_sq(i) {
                        1 => p += 1,
                        -1 => q += 1,
                        0 => r += 1,
                        _ => {}
                    }
                }
                Generic { p, q, r }
            }
        }
    }

    /// Check if two metrics are compatible for operations.
    ///
    /// Two metrics are compatible if they have the same dimension and signature.
    pub fn is_compatible(&self, other: &Self) -> bool {
        self.dimension() == other.dimension() && self.signature() == other.signature()
    }

    /// Normalize to Generic form for comparison.
    ///
    /// This converts any Metric variant to its Generic equivalent,
    /// allowing comparison of metrics with different representations.
    pub fn to_generic(&self) -> Self {
        let (p, q, r) = self.signature();
        Metric::Generic { p, q, r }
    }

    /// Create a Metric from (p, q, r) signature.
    ///
    /// This creates the most appropriate Metric variant based on the signature:
    /// - (n, 0, 0) -> Euclidean(n)
    /// - (0, n, 0) -> NonEuclidean(n)
    /// - (1, n-1, 0) -> Minkowski(n)
    /// - (n-1, 0, 1) -> PGA(n)
    /// - otherwise -> Generic { p, q, r }
    pub fn from_signature(p: usize, q: usize, r: usize) -> Self {
        let n = p + q + r;
        if q == 0 && r == 0 {
            Metric::Euclidean(n)
        } else if p == 0 && r == 0 {
            Metric::NonEuclidean(n)
        } else if p == 1 && r == 0 && q == n.saturating_sub(1) {
            Metric::Minkowski(n)
        } else if q == 1 && r == 0 && p == n.saturating_sub(1) {
            Metric::Lorentzian(n)
        } else if q == 0 && r == 1 && p == n.saturating_sub(1) {
            Metric::PGA(n)
        } else {
            Metric::Generic { p, q, r }
        }
    }

    /// Create a Custom Metric from an explicit signs array.
    ///
    /// # Arguments
    /// * `signs` - Array of signs for each basis vector (+1, -1, or 0)
    ///
    /// # Returns
    /// * `Ok(Metric)` - A Custom metric with the specified signs
    /// * `Err(MetricError)` - If dimension is 0 or exceeds 64
    #[cfg(feature = "alloc")]
    pub fn from_signs(signs: &[i32]) -> Result<Self, MetricError> {
        let dim = signs.len();
        if dim == 0 {
            return Err(MetricError::invalid_dimension("dimension cannot be zero"));
        }
        if dim > 64 {
            return Err(MetricError::invalid_dimension(
                "dimension exceeds bitmask capacity (max 64)",
            ));
        }

        let mut neg_mask = 0u64;
        let mut zero_mask = 0u64;

        for (i, &sign) in signs.iter().enumerate() {
            match sign {
                1 => {} // Default is +1
                -1 => neg_mask |= 1 << i,
                0 => zero_mask |= 1 << i,
                _ => {
                    return Err(MetricError::validation_failed("sign must be +1, -1, or 0"));
                }
            }
        }

        Ok(Metric::Custom {
            dim,
            neg_mask,
            zero_mask,
        })
    }

    /// Extract signs as a vector.
    ///
    /// Returns a Vec containing the sign (+1, -1, or 0) of each basis vector.
    #[cfg(feature = "alloc")]
    pub fn to_signs(&self) -> Vec<i32> {
        let dim = self.dimension();
        (0..dim).map(|i| self.sign_of_sq(i)).collect()
    }
}
