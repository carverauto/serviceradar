/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use deep_causality_algebra::RealField;
use deep_causality_metric::Metric;
use deep_causality_num::FromPrimitive;
use deep_causality_tensor::CausalTensor;

use crate::{Simplex, SimplicialComplex};

mod curvature;
mod has_hodge_star;

#[derive(Debug, Clone, PartialEq)]
pub struct ReggeGeometry<R: RealField> {
    // Lengths of the 1-simplices (Edges)
    pub(crate) edge_lengths: CausalTensor<R>,
}

impl<R> ReggeGeometry<R>
where
    R: RealField + FromPrimitive,
{
    pub fn new(edge_lengths: CausalTensor<R>) -> Self {
        ReggeGeometry { edge_lengths }
    }

    /// Computes the Riemannian Metric for a specific simplex using the Cayley-Menger
    /// determinant approach to determine the metric signature from edge lengths.
    ///
    /// This properly detects whether the local geometry is Euclidean, Lorentzian,
    /// or has a more general signature by analyzing the eigenvalues of the Gram matrix
    /// constructed from squared edge lengths.
    ///
    /// # Arguments
    /// * `complex` - The simplicial complex containing the simplex
    /// * `grade` - The dimension of the simplex
    /// * `index` - The index of the simplex within its skeleton
    ///
    /// # Returns
    /// The metric signature derived from edge length geometry.
    pub fn metric_at(&self, complex: &SimplicialComplex<R>, grade: usize, index: usize) -> Metric {
        // 1. Retrieve the simplex
        let simplex = &complex.skeletons[grade].simplices[index];
        let n_vertices = simplex.vertices.len();

        // For 0-simplices (vertices), no meaningful metric
        if n_vertices <= 1 {
            return Metric::Euclidean(0);
        }

        // 2. Collect all squared edge lengths for this simplex
        let squared_lengths = self.collect_squared_edge_lengths(complex, simplex);

        // 3. Compute signature from Cayley-Menger Gram matrix
        let (p, q, r) = compute_signature(&squared_lengths, n_vertices);

        // 4. Return the appropriate metric
        Metric::from_signature(p, q, r)
    }

    /// Returns a Euclidean metric for a specific simplex without computing signature.
    ///
    /// This is a fast fallback for cases where the geometry is known to be Euclidean
    /// (e.g., standard triangulations in Euclidean space).
    ///
    /// # Arguments
    /// * `grade` - The dimension of the simplex (determines metric dimension)
    ///
    /// # Returns
    /// A Euclidean metric of the specified dimension.
    pub fn euclidean_metric_at(&self, grade: usize) -> Metric {
        Metric::Euclidean(grade)
    }

    /// Collects squared edge lengths for all edges in a simplex.
    fn collect_squared_edge_lengths(
        &self,
        complex: &SimplicialComplex<R>,
        simplex: &Simplex,
    ) -> Vec<R> {
        let n_vertices = simplex.vertices.len();
        let mut squared_lengths = Vec::new();

        // Iterate over all unique pairs of vertices to find edges
        for i in 0..n_vertices {
            for j in (i + 1)..n_vertices {
                let u = simplex.vertices[i];
                let v = simplex.vertices[j];

                // Construct edge simplex to look up index
                let edge = Simplex {
                    vertices: vec![u, v],
                };

                // Find edge index in 1-skeleton
                if let Some(edge_idx) = complex.skeletons[1].get_index(&edge) {
                    // Get length from tensor
                    let length = self.edge_lengths.as_slice()[edge_idx];
                    squared_lengths.push(length * length);
                } else {
                    // Should not happen in a valid complex
                    panic!("Edge not found in 1-skeleton");
                }
            }
        }

        squared_lengths
    }
}

/// Computes the metric signature (p, q, r) from squared edge lengths using
/// the Cayley-Menger Gram matrix approach.
///
/// The Gram matrix G is constructed such that G_ij = (d_0i² + d_0j² - d_ij²) / 2,
/// where d_ij is the distance between vertices i and j.
///
/// The signature is determined by counting:
/// - p: positive eigenvalues (Euclidean dimensions)
/// - q: negative eigenvalues (timelike dimensions in Lorentzian geometry)
/// - r: zero eigenvalues (degenerate dimensions)
///
/// # Arguments
/// * `squared_lengths` - Vector of squared edge lengths in order:
///   (0,1), (0,2), ..., (0,n-1), (1,2), ..., (n-2,n-1)
/// * `n_vertices` - Number of vertices in the simplex
///
/// # Returns
/// Tuple (p, q, r) representing the metric signature.
fn compute_signature<R>(squared_lengths: &[R], n_vertices: usize) -> (usize, usize, usize)
where
    R: RealField + FromPrimitive,
{
    // For a k-simplex with (k+1) vertices, the intrinsic dimension is k
    let k = n_vertices.saturating_sub(1);

    if k == 0 {
        return (0, 0, 0);
    }

    // Build the distance matrix D where D[i][j] = d_ij²
    let mut d_sq = vec![vec![R::zero(); n_vertices]; n_vertices];
    let mut idx = 0;

    #[allow(clippy::needless_range_loop)]
    for i in 0..n_vertices {
        for j in (i + 1)..n_vertices {
            if idx < squared_lengths.len() {
                d_sq[i][j] = squared_lengths[idx];
                d_sq[j][i] = squared_lengths[idx];
                idx += 1;
            }
        }
    }

    // Build Gram matrix G where G[i][j] = (d[0][i]² + d[0][j]² - d[i][j]²) / 2
    // This is for vertices 1..n-1 (excluding vertex 0 as origin)
    let gram_dim = k; // Dimension is (n_vertices - 1)
    let mut gram = vec![vec![R::zero(); gram_dim]; gram_dim];
    let two = <R as FromPrimitive>::from_f64(2.0).expect("2.0 is representable in every RealField");

    for i in 0..gram_dim {
        for j in 0..gram_dim {
            // i+1 and j+1 because we skip vertex 0
            let d_0i_sq = d_sq[0][i + 1];
            let d_0j_sq = d_sq[0][j + 1];
            let d_ij_sq = d_sq[i + 1][j + 1];
            gram[i][j] = (d_0i_sq + d_0j_sq - d_ij_sq) / two;
        }
    }

    // Compute eigenvalues using power iteration / Jacobi method
    let eigenvalues = compute_eigenvalues(&gram, gram_dim);

    // Count positive, negative, and zero eigenvalues
    let epsilon =
        <R as FromPrimitive>::from_f64(1e-10).expect("1e-10 is representable in every RealField"); // Tolerance for zero detection
    let mut p = 0usize;
    let mut q = 0usize;
    let mut r_zero = 0usize;

    for &ev in &eigenvalues {
        if ev > epsilon {
            p += 1;
        } else if ev < -epsilon {
            q += 1;
        } else {
            r_zero += 1;
        }
    }

    (p, q, r_zero)
}

/// Computes eigenvalues of a symmetric matrix using the Jacobi eigenvalue algorithm.
///
/// This is a simple, robust algorithm suitable for small matrices (typical for simplex dimensions).
pub(crate) fn compute_eigenvalues<R>(matrix: &[Vec<R>], n: usize) -> Vec<R>
where
    R: RealField + FromPrimitive,
{
    if n == 0 {
        return vec![];
    }

    if n == 1 {
        return vec![matrix[0][0]];
    }

    // Copy matrix for in-place modification
    let mut a: Vec<Vec<R>> = matrix.to_vec();

    // Jacobi rotation method for small symmetric matrices
    let max_iterations = 100;
    let tolerance = <R as FromPrimitive>::from_f64(1e-12).expect("1e-12 fits in every RealField");
    let two = <R as FromPrimitive>::from_f64(2.0).expect("2.0 fits in every RealField");
    let half = <R as FromPrimitive>::from_f64(0.5).expect("0.5 fits in every RealField");
    let tiny = <R as FromPrimitive>::from_f64(1e-15).expect("1e-15 fits in every RealField");
    let pi_over_four = <R as FromPrimitive>::from_f64(std::f64::consts::FRAC_PI_4)
        .expect("FRAC_PI_4 fits in every RealField");

    for _ in 0..max_iterations {
        // Find largest off-diagonal element
        let mut max_off_diag = R::zero();
        let mut p = 0;
        let mut q_idx = 1;

        for (i, row) in a.iter().enumerate().take(n) {
            for (j, val) in row.iter().enumerate().skip(i + 1) {
                let abs_val = val.abs();
                if abs_val > max_off_diag {
                    max_off_diag = abs_val;
                    p = i;
                    q_idx = j;
                }
            }
        }

        // Check convergence
        if max_off_diag < tolerance {
            break;
        }

        // Compute rotation angle
        let diff = a[q_idx][q_idx] - a[p][p];
        let theta = if diff.abs() < tiny {
            pi_over_four
        } else {
            half * (two * a[p][q_idx] / diff).atan()
        };

        let cos_t = theta.cos();
        let sin_t = theta.sin();

        // Apply Jacobi rotation
        let a_pp = a[p][p];
        let a_qq = a[q_idx][q_idx];
        let a_pq = a[p][q_idx];

        a[p][p] = cos_t * cos_t * a_pp - two * cos_t * sin_t * a_pq + sin_t * sin_t * a_qq;
        a[q_idx][q_idx] = sin_t * sin_t * a_pp + two * cos_t * sin_t * a_pq + cos_t * cos_t * a_qq;
        a[p][q_idx] = R::zero();
        a[q_idx][p] = R::zero();

        // Update other elements
        #[allow(clippy::needless_range_loop)]
        for i in 0..n {
            if i != p && i != q_idx {
                let a_ip = a[i][p];
                let a_iq = a[i][q_idx];
                a[i][p] = cos_t * a_ip - sin_t * a_iq;
                a[p][i] = a[i][p];
                a[i][q_idx] = sin_t * a_ip + cos_t * a_iq;
                a[q_idx][i] = a[i][q_idx];
            }
        }
    }

    // Extract diagonal (eigenvalues)
    (0..n).map(|i| a[i][i]).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use deep_causality_algebra::Real;
    #[test]
    fn test_compute_signature_equilateral_triangle() {
        // Equilateral triangle with side length 1: should be Euclidean (2, 0, 0)
        let squared_lengths = vec![1.0, 1.0, 1.0]; // All edges equal
        let (p, q, r) = compute_signature(&squared_lengths, 3);
        assert_eq!(p, 2);
        assert_eq!(q, 0);
        assert_eq!(r, 0);
    }

    #[test]
    fn test_compute_signature_tetrahedron() {
        // Regular tetrahedron with side length 1: should be Euclidean (3, 0, 0)
        let squared_lengths = vec![1.0, 1.0, 1.0, 1.0, 1.0, 1.0]; // 6 edges
        let (p, q, r) = compute_signature(&squared_lengths, 4);
        assert_eq!(p, 3);
        assert_eq!(q, 0);
        assert_eq!(r, 0);
    }

    #[test]
    fn test_compute_eigenvalues_identity() {
        let matrix = vec![vec![1.0, 0.0], vec![0.0, 1.0]];
        let eigenvalues = compute_eigenvalues(&matrix, 2);
        assert!((eigenvalues[0] - 1.0).abs() < 1e-10);
        assert!((eigenvalues[1] - 1.0).abs() < 1e-10);
    }
}
