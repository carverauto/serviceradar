/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::ConstTree;

// Conveniently create a leaf node from a value.
impl<T> From<T> for ConstTree<T> {
    fn from(value: T) -> Self {
        Self::new(value)
    }
}
// Egonomics for creating a leaf node from a reference,
impl<T: Clone> From<&T> for ConstTree<T> {
    /// Creates a new leaf `ConstTree` by cloning the provided value.
    fn from(value: &T) -> Self {
        Self::new(value.clone())
    }
}
