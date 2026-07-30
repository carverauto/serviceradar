/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use core::slice::SliceIndex;

mod display;
mod getters;

use crate::traits::cell::Cell;

impl Cell for Simplex {
    fn dim(&self) -> usize {
        self.vertices.len().saturating_sub(1)
    }

    fn boundary(&self) -> Vec<(Self, i8)> {
        // ∂[v0, ..., vk] = sum_{i=0}^{k} (-1)^i * [v0, ..., v_{i-1}, v_{i+1}, ..., vk]
        if self.vertices.len() <= 1 {
            return Vec::new();
        }
        let mut faces = Vec::with_capacity(self.vertices.len());
        for i in 0..self.vertices.len() {
            let mut face_vertices = self.vertices.clone();
            face_vertices.remove(i);
            let sign: i8 = if i % 2 == 0 { 1 } else { -1 };
            faces.push((
                Simplex {
                    vertices: face_vertices,
                },
                sign,
            ));
        }
        faces
    }
}

/// A combinatorial simplex defined by sorted vertex indices.
/// Order is strictly increasing to ensure canonical representation.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Simplex {
    pub(crate) vertices: Vec<usize>,
}

impl Simplex {
    pub fn new(mut vertices: Vec<usize>) -> Self {
        vertices.sort_unstable();
        Self { vertices }
    }

    /// Checks if a vertex is part of the simplex using binary search.
    pub fn contains_vertex(&self, vertex: &usize) -> bool {
        self.vertices.binary_search(vertex).is_ok()
    }

    /// Returns a sub-simplex defined by the given range of vertices.
    pub fn subsimplex<R>(&self, range: R) -> Self
    where
        R: SliceIndex<[usize], Output = [usize]>,
    {
        Simplex {
            vertices: self.vertices[range].to_vec(),
        }
    }
}
