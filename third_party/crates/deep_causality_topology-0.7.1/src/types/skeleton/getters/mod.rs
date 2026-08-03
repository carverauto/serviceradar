/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{Simplex, Skeleton};

impl Skeleton {
    pub fn dim(&self) -> usize {
        self.dim
    }

    pub fn simplices(&self) -> &Vec<Simplex> {
        &self.simplices
    }
}
