/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{Distribution, Fill, RngCore, SampleRange, SampleUniform};
use crate::{Iter, Map, StandardUniform};

impl<T: Rng> Rng for &mut T {}

pub trait Rng: RngCore {
    #[inline]
    fn random<T>(&mut self) -> T
    where
        StandardUniform: Distribution<T>,
    {
        StandardUniform.sample(self)
    }

    #[inline]
    fn random_iter<T>(&mut self) -> Iter<StandardUniform, &mut Self, T>
    where
        Self: Sized,
        StandardUniform: Distribution<T>,
    {
        StandardUniform.sample_iter(self)
    }

    #[track_caller]
    fn random_range<T, R>(&mut self, range: R) -> T
    where
        T: SampleUniform,
        R: SampleRange<T>,
    {
        assert!(!range.is_empty(), "cannot sample empty range");
        range.sample_single(self).unwrap()
    }

    #[inline]
    #[track_caller]
    fn random_bool(&mut self, p: f64) -> bool {
        if !(0.0..=1.0).contains(&p) {
            panic!("p={} is outside range [0.0, 1.0]", p);
        }
        self.next_u64() as f64 / (u64::MAX as f64) <= p
    }

    #[inline]
    #[track_caller]
    fn random_ratio(&mut self, numerator: u32, denominator: u32) -> bool {
        if denominator == 0 || numerator > denominator {
            panic!(
                "p={}/{} is outside range [0.0, 1.0]",
                numerator, denominator
            );
        }
        self.next_u64() % (denominator as u64) < (numerator as u64)
    }

    fn sample<T, D: Distribution<T>>(&mut self, distr: D) -> T {
        distr.sample(self)
    }

    fn sample_iter<T, D>(&mut self, distr: D) -> Iter<D, &mut Self, T>
    where
        D: Distribution<T>,
        Self: Sized,
    {
        distr.sample_iter(self)
    }

    #[track_caller]
    fn fill<T: Fill + ?Sized>(&mut self, dest: &mut T) {
        dest.fill(self)
    }

    fn map<T, S, F>(&mut self, func: F) -> Map<StandardUniform, F, T, S>
    where
        StandardUniform: Distribution<T>,
        F: Fn(T) -> S,
    {
        Map {
            distr: StandardUniform,
            func,
            phantom: core::marker::PhantomData,
        }
    }
}
