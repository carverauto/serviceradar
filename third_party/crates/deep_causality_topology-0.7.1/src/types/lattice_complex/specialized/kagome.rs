/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

/// Kagome lattice in 2D.
/// Used in frustrated magnets, spin liquids.
pub struct KagomeLattice {
    size: [usize; 2],
    periodic: [bool; 2],
}

impl KagomeLattice {
    pub fn new(size: [usize; 2], periodic: [bool; 2]) -> Self {
        Self { size, periodic }
    }

    pub fn size(&self) -> &[usize; 2] {
        &self.size
    }

    pub fn periodic(&self) -> &[bool; 2] {
        &self.periodic
    }
}
