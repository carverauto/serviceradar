/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{Uncertain, UncertainError, UncertainNodeContent};
use std::sync::Arc;

// `point` / `normal` / `uniform` are the shared generic constructors in `uncertain_real`
// (a single impl, so `Uncertain::normal(0.0, 1.0)` still infers `f64`). The methods below
// are f64-specific.
impl Uncertain<f64> {
    pub fn from_samples(samples: &[f64]) -> Self {
        if samples.is_empty() {
            return Self::point(0.0);
        }

        let mean = samples.iter().sum::<f64>() / samples.len() as f64;
        let variance = if samples.len() > 1 {
            samples.iter().map(|s| (s - mean).powi(2)).sum::<f64>() / (samples.len() - 1) as f64
        } else {
            0.0
        };
        let std_dev = variance.sqrt();

        Self::normal(mean, std_dev)
    }

    pub fn estimate_probability_exceeds(
        &self,
        threshold: f64,
        num_samples: usize,
    ) -> Result<f64, UncertainError> {
        if num_samples == 0 {
            return Ok(0.0);
        }
        let samples = self.take_samples(num_samples)?;
        let count = samples.iter().filter(|&&s| s > threshold).count();
        Ok(count as f64 / num_samples as f64)
    }

    pub fn map<F>(&self, func: F) -> Self
    where
        F: Fn(f64) -> f64 + Send + Sync + 'static,
    {
        Self::from_root_node(UncertainNodeContent::FunctionOpF64 {
            func: Arc::new(func),
            operand: self.root_node.clone(),
        })
    }

    pub fn map_to_bool<F>(&self, func: F) -> Uncertain<bool>
    where
        F: Fn(f64) -> bool + Send + Sync + 'static,
    {
        Uncertain::from_root_node(UncertainNodeContent::FunctionOpBool {
            func: Arc::new(func),
            operand: self.root_node.clone(),
        })
    }
}
