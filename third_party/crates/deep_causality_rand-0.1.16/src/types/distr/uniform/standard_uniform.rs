/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{Distribution, Rng};

#[derive(Clone, Copy, Debug, Default)]
pub struct StandardUniform;

impl Distribution<u64> for StandardUniform {
    fn sample<R: Rng + ?Sized>(&self, rng: &mut R) -> u64 {
        rng.next_u64()
    }
}

impl Distribution<u32> for StandardUniform {
    fn sample<R: Rng + ?Sized>(&self, rng: &mut R) -> u32 {
        rng.next_u32()
    }
}

impl Distribution<bool> for StandardUniform {
    fn sample<R: Rng + ?Sized>(&self, rng: &mut R) -> bool {
        rng.next_u64().is_multiple_of(2) // Simple boolean generation
    }
}
