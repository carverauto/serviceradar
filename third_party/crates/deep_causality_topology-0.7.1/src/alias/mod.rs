/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use deep_causality_tensor::CausalTensor;

/// Adjacency Matrix mapped to backend (Shape: [N, N])
pub type AdjacencyMatrix<T> = CausalTensor<T>;

/// Incidence Matrix mapped to backend (Shape: [Nodes, Edges])
pub type IncidenceMatrix<T> = CausalTensor<T>;

/// Laplacian Matrix (L = D - A)
pub type LaplacianMatrix<T> = CausalTensor<T>;

/// Manifold Metric Tensor (g_{mn})
pub type MetricTensor<T> = CausalTensor<T>;
