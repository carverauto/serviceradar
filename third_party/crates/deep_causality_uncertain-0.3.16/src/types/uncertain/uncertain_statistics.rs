/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{Uncertain, UncertainError};

impl Uncertain<f64> {
    /// Estimates the expected value (mean) of the uncertain f64 value by taking multiple samples.
    pub fn expected_value(&self, num_samples: usize) -> Result<f64, UncertainError> {
        if num_samples == 0 {
            return Ok(0.0); // Or return an error, depending on desired behavior for 0 samples
        }
        let mut sum = 0.0;
        for i in 0..num_samples {
            sum += self.sample_with_index(i as u64)?;
        }
        Ok(sum / num_samples as f64)
    }

    /// Estimates the standard deviation of the uncertain f64 value by taking multiple samples.
    pub fn standard_deviation(&self, num_samples: usize) -> Result<f64, UncertainError> {
        if num_samples <= 1 {
            return Ok(0.0); // Standard deviation is 0 for 0 or 1 samples
        }

        let samples: Vec<f64> = (0..num_samples)
            .map(|i| self.sample_with_index(i as u64))
            .collect::<Result<Vec<f64>, UncertainError>>()?;

        let mean = samples.iter().sum::<f64>() / num_samples as f64;

        let variance: f64 =
            samples.iter().map(|&x| (x - mean).powi(2)).sum::<f64>() / (num_samples - 1) as f64; // Use (n-1) for sample standard deviation

        Ok(variance.sqrt())
    }
}
