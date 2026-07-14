/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{Distribution, Rng};

#[derive(Debug, Clone)]
pub struct Iter<D, R, T> {
    pub distr: D,
    pub rng: R,
    pub phantom: core::marker::PhantomData<T>,
}

impl<D, R, T> Iterator for Iter<D, R, T>
where
    D: Distribution<T>,
    R: Rng,
{
    type Item = T;

    fn next(&mut self) -> Option<Self::Item> {
        Some(self.distr.sample(&mut self.rng))
    }
}
