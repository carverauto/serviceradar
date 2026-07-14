/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{Distribution, Rng};

#[derive(Debug, Clone)]
pub struct Map<D, F, T, S> {
    pub distr: D,
    pub func: F,
    pub phantom: core::marker::PhantomData<(T, S)>,
}

impl<D, F, T, S> Distribution<S> for Map<D, F, T, S>
where
    D: Distribution<T>,
    F: Fn(T) -> S,
{
    fn sample<R: Rng + ?Sized>(&self, rng: &mut R) -> S {
        let value = self.distr.sample(rng);
        (self.func)(value)
    }
}
