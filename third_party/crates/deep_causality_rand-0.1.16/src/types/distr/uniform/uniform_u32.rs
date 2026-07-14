/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{Rng, SampleBorrow, SampleRange, SampleUniform, UniformSampler};
use crate::{RngError, UniformDistributionError};
use std::ops::Range;

#[derive(Debug, Copy, Clone, PartialEq, Eq)]
pub struct UniformU32 {
    low: u32,
    high: u32,
}

impl UniformSampler for UniformU32 {
    type X = u32;

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
        Ok(UniformU32 {
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
        // Use checked_add to avoid overflow when high_val == u32::MAX
        // If overflow occurs, use 0 as a sentinel for "full range to MAX"
        let range_end = high_val.checked_add(1).unwrap_or(0);
        Ok(UniformU32 {
            low: low_val,
            high: range_end,
        })
    }

    fn sample<R: Rng + ?Sized>(&self, rng: &mut R) -> Self::X {
        // Handle special case: when high == 0 and low > 0, it means we want [low, u32::MAX]
        // (overflow wraparound from checked_add)
        if self.high == 0 && self.low > 0 {
            // Full range from low to u32::MAX
            let range_size = u32::MAX - self.low + 1; // This is safe: range_size >= 1
            if range_size == 0 {
                // Special case: low == 0 means full u32 range, just return any value
                return rng.next_u32();
            }
            return self.low.wrapping_add(rng.next_u32() % range_size);
        }
        // Handle single-value range (low == high means range_end == low + 1, so high - low == 1)
        if self.high == self.low {
            // This shouldn't happen with our new validation, but just in case
            return self.low;
        }
        self.low + (rng.next_u32() % (self.high - self.low))
    }
}

impl SampleUniform for u32 {
    type Sampler = UniformU32;
}
impl SampleRange<u32> for Range<u32> {
    fn sample_single<R: Rng + ?Sized>(self, rng: &mut R) -> Result<u32, RngError> {
        // Changed RngCore to Rng
        let uniform = UniformU32::new(self.start, self.end)?;
        Ok(uniform.sample(rng))
    }

    fn is_empty(&self) -> bool {
        self.start >= self.end
    }
}
