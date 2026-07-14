/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{Rng, RngError};
use std::ops::Range;

pub trait SampleRange<T> {
    fn sample_single<R: Rng + ?Sized>(self, rng: &mut R) -> Result<T, RngError>;

    fn is_empty(&self) -> bool;
}

impl SampleRange<f32> for Range<f32> {
    fn sample_single<R: Rng + ?Sized>(self, rng: &mut R) -> Result<f32, RngError> {
        if self.is_empty() {
            return Err(RngError::InvalidRange(
                "Invalid range: low must be less than high".to_string(),
            ));
        }
        let random_val: f32 = rng.random(); // Generates a random f32 in [0.0, 1.0)
        Ok(self.start + (self.end - self.start) * random_val)
    }

    fn is_empty(&self) -> bool {
        self.start >= self.end
    }
}

impl SampleRange<f64> for Range<f64> {
    fn sample_single<R: Rng + ?Sized>(self, rng: &mut R) -> Result<f64, RngError> {
        if self.is_empty() {
            return Err(RngError::InvalidRange(
                "Invalid range: low must be less than high".to_string(),
            ));
        }
        let random_val: f64 = rng.random(); // Generates a random f64 in [0.0, 1.0)
        Ok(self.start + (self.end - self.start) * random_val)
    }

    fn is_empty(&self) -> bool {
        self.start >= self.end
    }
}
