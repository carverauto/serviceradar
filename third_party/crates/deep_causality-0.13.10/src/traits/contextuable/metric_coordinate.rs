/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::Coordinate;
use crate::traits::contextuable::metric::Metric;

/// Represents coordinate-bearing entities that also implement distance metrics.
///
/// This trait is a composition of [`Coordinate`] and [`Metric`], intended for
/// **Euclidean or pseudo-Euclidean spaces** where distance can be meaningfully
/// computed between coordinate positions.
///
/// # Example Use Cases
/// - 3D physical space (x, y, z)
/// - Latent vector spaces in embeddings
/// - Discrete grids with uniform spacing
pub trait MetricCoordinate<V>: Coordinate<V> + Metric<V> {}
