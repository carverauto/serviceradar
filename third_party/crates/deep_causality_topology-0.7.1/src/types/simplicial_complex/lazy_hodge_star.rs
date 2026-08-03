/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Lazy lumped-mass Hodge ⋆ population for `SimplicialComplex<T>`.
//!
//! The construction was previously inlined inside `PointCloud::triangulate`,
//! eagerly computed for every triangulated complex regardless of whether the
//! caller consumed the Hodge ⋆ surface. That conflated topological (TDA /
//! clique-complex / Euler-characteristic) consumers with geometric (DEC / Hodge
//! ⋆ / Laplacian) consumers and forced TDA callers to satisfy geometric
//! preconditions they never used.
//!
//! This module exposes the build as a single `pub(crate)` function that the
//! lazy accessor invokes on first read. The top-volume degeneracy rejection
//! lives here, not in `triangulate`. TDA-only consumers never reach this code
//! path; DEC consumers see the unified `"top-dimensional simplex below
//! tolerance"` error at the point of access.

use crate::{Simplex, Skeleton, TopologyError};
use deep_causality_algebra::RealField;
use deep_causality_num::FromPrimitive;
use deep_causality_sparse::CsrMatrix;

fn euclidean_distance<T>(p1: &[T], p2: &[T]) -> T
where
    T: RealField,
{
    let mut acc = T::zero();
    for (a, b) in p1.iter().zip(p2.iter()) {
        let diff = *a - *b;
        acc += diff * diff;
    }
    acc.sqrt()
}

/// Cayley-Menger volume of a simplex against the supplied coordinate slab.
/// Returns `T::zero()` for degenerate simplices (singular Gram matrix or
/// non-positive determinant); the caller surfaces the degeneracy through the
/// top-volume threshold compare in [`build_lumped_mass_hodge_star`].
fn simplex_volume<T>(simplex: &Simplex, points: &[T], dim: usize) -> T
where
    T: RealField + FromPrimitive,
{
    let k = simplex.vertices.len();
    if k == 0 {
        return T::zero();
    }
    if k == 1 {
        return T::one();
    }

    if k == 2 {
        let p1 = &points[simplex.vertices[0] * dim..(simplex.vertices[0] + 1) * dim];
        let p2 = &points[simplex.vertices[1] * dim..(simplex.vertices[1] + 1) * dim];
        return euclidean_distance(p1, p2);
    }

    let v0 = &points[simplex.vertices[0] * dim..(simplex.vertices[0] + 1) * dim];
    let mut vectors = Vec::new();
    for i in 1..k {
        let vi = &points[simplex.vertices[i] * dim..(simplex.vertices[i] + 1) * dim];
        let vec_i: Vec<T> = vi.iter().zip(v0.iter()).map(|(&a, &b)| a - b).collect();
        vectors.push(vec_i);
    }

    let mut matrix_data = Vec::new();
    let n_vecs = k - 1;

    for i in 0..n_vecs {
        for j in 0..n_vecs {
            let mut dot = T::zero();
            for (a, b) in vectors[i].iter().zip(vectors[j].iter()) {
                dot += *a * *b;
            }
            matrix_data.push(dot);
        }
    }

    let det = gaussian_determinant(&mut matrix_data, n_vecs);

    if det <= T::zero() {
        return T::zero();
    }

    let mut factorial: usize = 1;
    for i in 1..=n_vecs {
        factorial *= i;
    }
    let factorial_t = <T as FromPrimitive>::from_usize(factorial)
        .expect("factorial of n_vecs fits in every RealField");

    det.sqrt() / factorial_t
}

fn gaussian_determinant<T>(mat: &mut [T], n: usize) -> T
where
    T: RealField + FromPrimitive,
{
    let mut det = T::one();
    let hundred = <T as FromPrimitive>::from_f64(100.0).expect("100.0 fits in every RealField");
    let pivot_threshold = T::epsilon() * hundred;
    for i in 0..n {
        let pivot = i * n + i;
        if mat[pivot].abs() < pivot_threshold {
            return T::zero();
        }
        det *= mat[pivot];

        for j in (i + 1)..n {
            let factor = mat[j * n + i] / mat[pivot];
            for k in i..n {
                let val = mat[i * n + k];
                mat[j * n + k] -= factor * val;
            }
        }
    }
    det
}

/// Builds the lumped-mass Hodge ⋆ operators for a simplicial complex from its
/// skeletons and the originating geometric data (coordinates + ambient
/// dimension).
///
/// Returns `Err(TopologyError::PointCloudError)` when the complex contains a
/// top-dimensional simplex of volume below `T::epsilon() * 100`. The error
/// message contains the substrings `"top-dimensional simplex"` and
/// `"below tolerance"` plus the offending simplex index.
///
/// Empty complexes (no skeletons) return `Ok(Vec::new())`.
pub(crate) fn build_lumped_mass_hodge_star<T>(
    skeletons: &[Skeleton],
    coords: &[T],
    dim: usize,
) -> Result<Vec<CsrMatrix<T>>, TopologyError>
where
    T: RealField + FromPrimitive,
{
    if skeletons.is_empty() {
        return Ok(Vec::new());
    }

    let max_dim = skeletons.len() - 1;

    let mut primal_volumes: Vec<Vec<T>> = Vec::with_capacity(skeletons.len());
    for skel in skeletons {
        let vols: Vec<T> = skel
            .simplices
            .iter()
            .map(|s| simplex_volume(s, coords, dim))
            .collect();
        primal_volumes.push(vols);
    }

    let hundred = <T as FromPrimitive>::from_f64(100.0).expect("100.0 fits in every RealField");
    let top_threshold = T::epsilon() * hundred;
    let max_dim_plus_one =
        <T as FromPrimitive>::from_usize(max_dim + 1).expect("max_dim + 1 fits in every RealField");

    let mut hodge_ops = Vec::with_capacity(skeletons.len());

    for k_dim in 0..=max_dim {
        let count = skeletons[k_dim].simplices.len();
        let mut triplets = Vec::new();

        for i in 0..count {
            let primal_vol = primal_volumes[k_dim][i];

            let mass_val = if k_dim == 0 {
                let mut dual_vol = T::zero();
                let n_skel = &skeletons[max_dim];
                let n_vols = &primal_volumes[max_dim];
                for (cell_idx, cell) in n_skel.simplices.iter().enumerate() {
                    if cell.contains_vertex(&i) {
                        dual_vol += n_vols[cell_idx];
                    }
                }
                dual_vol / max_dim_plus_one
            } else if k_dim == max_dim {
                if primal_vol > top_threshold {
                    T::one() / primal_vol
                } else {
                    return Err(TopologyError::PointCloudError(format!(
                        "hodge_star_operators: top-dimensional simplex at index {} has volume below tolerance (T::epsilon() * 100), indicating degenerate input geometry",
                        i
                    )));
                }
            } else {
                debug_assert!(
                    primal_vol > T::zero(),
                    "intermediate-grade simplex has non-positive primal volume; upstream duplicate-point check and top-volume rejection should have caught this"
                );
                primal_vol
            };

            triplets.push((i, i, mass_val));
        }

        hodge_ops.push(CsrMatrix::from_triplets(count, count, &triplets).unwrap());
    }

    Ok(hodge_ops)
}
