/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{Simplex, SimplicialComplex, Skeleton};
use deep_causality_num::Zero;
use deep_causality_sparse::CsrMatrix;
use deep_causality_tensor::CausalTensor;

/// Creates a simple triangle (2-simplex) simplicial complex
/// Vertices: 0, 1, 2
/// Edges: (0,1), (0,2), (1,2)
/// Face: (0,1,2)
pub fn create_triangle_complex() -> SimplicialComplex<f64> {
    // 0-skeleton: vertices
    let vertices = vec![
        Simplex::new(vec![0]),
        Simplex::new(vec![1]),
        Simplex::new(vec![2]),
    ];
    let skeleton_0 = Skeleton::new(0, vertices);

    // 1-skeleton: edges
    let edges = vec![
        Simplex::new(vec![0, 1]),
        Simplex::new(vec![0, 2]),
        Simplex::new(vec![1, 2]),
    ];
    let skeleton_1 = Skeleton::new(1, edges);

    // 2-skeleton: face
    let faces = vec![Simplex::new(vec![0, 1, 2])];
    let skeleton_2 = Skeleton::new(2, faces);

    // Boundary operator d1: edges -> vertices
    // For edge (0,1): vertex 1 - vertex 0
    let d1 = CsrMatrix::from_triplets(
        3, // 3 vertices
        3, // 3 edges
        &[
            (1, 0, 1i8),
            (0, 0, -1),
            (2, 1, 1),
            (0, 1, -1),
            (2, 2, 1),
            (1, 2, -1),
        ],
    )
    .unwrap();

    // Boundary operator d2: faces -> edges
    let d2 = CsrMatrix::from_triplets(
        3, // 3 edges
        1, // 1 face
        &[(0, 0, 1i8), (1, 0, -1), (2, 0, 1)],
    )
    .unwrap();

    let boundary_ops = vec![d1, d2];

    let coboundary_ops = vec![];

    SimplicialComplex::new(
        vec![skeleton_0, skeleton_1, skeleton_2],
        boundary_ops,
        coboundary_ops,
        Vec::new(),
    )
}

/// Creates a tensor with default values for testing
pub fn create_test_tensor<T>(size: usize) -> CausalTensor<T>
where
    T: Default + Copy + Zero,
{
    CausalTensor::new(vec![T::zero(); size], vec![size]).unwrap()
}

/// Creates a simple line graph (2 vertices, 1 edge)
pub fn create_line_complex() -> SimplicialComplex<f64> {
    let vertices = vec![Simplex::new(vec![0]), Simplex::new(vec![1])];
    let skeleton_0 = Skeleton::new(0, vertices);

    let edges = vec![Simplex::new(vec![0, 1])];
    let skeleton_1 = Skeleton::new(1, edges);

    let d1 = CsrMatrix::from_triplets(2, 1, &[(1, 0, 1i8), (0, 0, -1)]).unwrap();

    SimplicialComplex::new(vec![skeleton_0, skeleton_1], vec![d1], vec![], Vec::new())
}
