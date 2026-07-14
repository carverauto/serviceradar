/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{
    SampledValue, Sampler, SequentialSampler, Uncertain, UncertainError, with_global_cache,
};
use deep_causality_rand::Rng;

// Sampling impl for Uncertain<f64>
impl Uncertain<f64> {
    pub fn sample_with_index(&self, sample_index: u64) -> Result<f64, UncertainError> {
        let key = (self.id, sample_index);

        let computed_value = with_global_cache(|cache| {
            cache.get_or_compute(key, || {
                let sampler = SequentialSampler;
                Sampler::<f64>::sample(&sampler, &self.root_node)
            })
        })?;

        match computed_value {
            SampledValue::Float(f) => Ok(f),
            _ => Err(UncertainError::UnsupportedTypeError(
                "Computed value type mismatch: Expected f64".to_string(),
            )),
        }
    }

    pub fn sample(&self) -> Result<f64, UncertainError> {
        let sample_index = deep_causality_rand::rng().random::<u64>();
        self.sample_with_index(sample_index)
    }

    pub fn take_samples(&self, n: usize) -> Result<Vec<f64>, UncertainError> {
        (0..n)
            .map(|_| {
                let sample_index = deep_causality_rand::rng().random::<u64>();
                self.sample_with_index(sample_index)
            })
            .collect()
    }
}

// Sampling impl for Uncertain<bool>
impl Uncertain<bool> {
    pub fn sample_with_index(&self, sample_index: u64) -> Result<bool, UncertainError> {
        let key = (self.id, sample_index);

        let computed_value = with_global_cache(|cache| {
            cache.get_or_compute(key, || {
                let sampler = SequentialSampler;
                Sampler::<bool>::sample(&sampler, &self.root_node)
            })
        })?;

        match computed_value {
            SampledValue::Bool(b) => Ok(b),
            _ => Err(UncertainError::UnsupportedTypeError(
                "Computed value type mismatch: Expected bool".to_string(),
            )),
        }
    }

    pub fn sample(&self) -> Result<bool, UncertainError> {
        let sample_index = deep_causality_rand::rng().random::<u64>();
        self.sample_with_index(sample_index)
    }

    pub fn take_samples(&self, n: usize) -> Result<Vec<bool>, UncertainError> {
        (0..n)
            .map(|_| {
                let sample_index = deep_causality_rand::rng().random::<u64>();
                self.sample_with_index(sample_index)
            })
            .collect()
    }
}
