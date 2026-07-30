/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use std::hash::Hash;

/// Marker trait for cell types in a chain complex.
pub trait Cell: Clone + Eq + Hash {
    /// Dimension of this cell.
    fn dim(&self) -> usize;

    /// Boundary as signed sum of lower-dimensional cells.
    /// This provides the algebraic topology structure.
    fn boundary(&self) -> Vec<(Self, i8)>;
}
