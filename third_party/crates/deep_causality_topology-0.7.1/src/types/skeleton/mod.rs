/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

mod display;
mod getters;

use crate::types::simplex::Simplex;

/// A collection of all simplices of dimension K.
#[derive(Debug, Clone, PartialEq)]

pub struct Skeleton {
    pub(crate) dim: usize,
    /// Canonical list of simplices. The index in this vector is the "Global ID".
    pub(crate) simplices: Vec<Simplex>,
}

impl Skeleton {
    pub fn new(dim: usize, simplices: Vec<Simplex>) -> Self {
        Self { dim, simplices }
    }
}

impl Skeleton {
    /// Find the global index of a simplex via binary search.
    pub fn get_index(&self, simplex: &Simplex) -> Option<usize> {
        self.simplices.binary_search(simplex).ok()
    }
}
