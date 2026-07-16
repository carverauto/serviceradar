/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{Coordinate, Identifiable};

/// Marks entities that have spatial semantics.
///
/// This is a composite trait that combines:
/// - [`Identifiable`] — uniquely tracked nodes
/// - [`Coordinate<V>`] — N-dimensional position or location
///
/// It does **not** require a metric, allowing support for:
/// - Symbolic zones
/// - Discrete lattice structures
/// - Topological graphs with no distance definition
///
/// Use this to model anything *located* in space—regardless of how space is defined.
pub trait Spatial<V>: Identifiable + Coordinate<V> {}
