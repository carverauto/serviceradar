/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

/// Defines a measurable relationship between two entities within the same space.
///
/// This trait abstracts over geometric or abstract "distance" computations.
/// It may represent physical distance, influence strength, semantic similarity,
/// or any scalar that satisfies the symmetry and triangle inequality properties
/// of a metric space—though these are not enforced by the trait.
///
/// Use this trait for types where **numeric comparison** between entities
/// makes sense (e.g. Euclidean points, time series, weighted graphs).
///
/// # Notes
/// - Units must match across implementations of `V`
/// - If you're implementing this in a curved or non-Euclidean space,
///   you may need to inject a metric tensor
///
pub trait Metric<V> {
    /// Computes a scalar distance or influence between `self` and `other`.
    fn distance(&self, other: &Self) -> V;
}
