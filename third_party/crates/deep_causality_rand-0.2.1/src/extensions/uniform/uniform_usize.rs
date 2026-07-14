/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{Rng, SampleBorrow, SampleRange, SampleUniform, UniformSampler};
use crate::{RngError, UniformDistributionError};
use std::ops::Range;

#[derive(Debug, Copy, Clone, PartialEq, Eq)]
pub struct UniformUsize {
    low: usize,
    high: usize,
}

impl UniformSampler for UniformUsize {
    type X = usize;

    fn new<B1, B2>(low: B1, high: B2) -> Result<Self, UniformDistributionError>
    where
        B1: SampleBorrow<Self::X> + Sized,
        B2: SampleBorrow<Self::X> + Sized,
    {
        let low_val = *low.borrow();
        let high_val = *high.borrow();
        if low_val >= high_val {
            return Err(UniformDistributionError::InvalidRange);
        }
        Ok(UniformUsize {
            low: low_val,
            high: high_val,
        })
    }

    fn new_inclusive<B1, B2>(low: B1, high: B2) -> Result<Self, UniformDistributionError>
    where
        B1: SampleBorrow<Self::X> + Sized,
        B2: SampleBorrow<Self::X> + Sized,
    {
        let low_val = *low.borrow();
        let high_val = *high.borrow();
        if low_val > high_val {
            return Err(UniformDistributionError::InvalidRange);
        }
        // Use checked_add to avoid overflow when high_val == usize::MAX
        let range_end = high_val.checked_add(1).unwrap_or(0);
        Ok(UniformUsize {
            low: low_val,
            high: range_end,
        })
    }

    fn sample<R: Rng + ?Sized>(&self, rng: &mut R) -> Self::X {
        // Handle special case: when high == 0 and low > 0, it means we want [low, usize::MAX]
        if self.high == 0 && self.low > 0 {
            let range_size = usize::MAX - self.low + 1;
            if range_size == 0 {
                return rng.next_u32() as usize;
            }
            return self.low.wrapping_add(rng.next_u32() as usize % range_size);
        }
        if self.high == self.low {
            return self.low;
        }
        self.low + (rng.next_u32() as usize % (self.high - self.low))
    }
}

impl SampleUniform for usize {
    type Sampler = UniformUsize;
}

impl SampleRange<usize> for Range<usize> {
    fn sample_single<R: Rng + ?Sized>(self, rng: &mut R) -> Result<usize, RngError> {
        // Changed RngCore to Rng
        let uniform = UniformUsize::new(self.start, self.end)?;
        Ok(uniform.sample(rng))
    }

    fn is_empty(&self) -> bool {
        self.start >= self.end
    }
}
