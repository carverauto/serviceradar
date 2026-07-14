/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{Rng, SampleBorrow, SampleRange, SampleUniform, UniformSampler};
use crate::{RngError, UniformDistributionError};

use std::ops::Range;

#[derive(Debug, Copy, Clone, PartialEq, Eq)]
pub struct UniformU64 {
    low: u64,
    high: u64,
}

impl UniformSampler for UniformU64 {
    type X = u64;

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
        Ok(UniformU64 {
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
        // Use checked_add to avoid overflow when high_val == u64::MAX
        let range_end = high_val.checked_add(1).unwrap_or(0);
        Ok(UniformU64 {
            low: low_val,
            high: range_end,
        })
    }

    fn sample<R: Rng + ?Sized>(&self, rng: &mut R) -> Self::X {
        // Handle special case: when high == 0 and low > 0, it means we want [low, u64::MAX]
        if self.high == 0 && self.low > 0 {
            let range_size = u64::MAX - self.low + 1;
            if range_size == 0 {
                return rng.next_u64();
            }
            return self.low.wrapping_add(rng.next_u64() % range_size);
        }
        if self.high == self.low {
            return self.low;
        }
        self.low + (rng.next_u64() % (self.high - self.low))
    }
}

impl SampleUniform for u64 {
    type Sampler = UniformU64;
}

impl SampleRange<u64> for Range<u64> {
    fn sample_single<R: Rng + ?Sized>(self, rng: &mut R) -> Result<u64, RngError> {
        // Changed RngCore to Rng
        let uniform = UniformU64::new(self.start, self.end)?;
        Ok(uniform.sample(rng))
    }

    fn is_empty(&self) -> bool {
        self.start >= self.end
    }
}
