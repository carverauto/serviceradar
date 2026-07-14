/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{
    DistributionEnum, IntoSampledValue, NormalDistributionParams, Uncertain, UncertainError,
    UncertainNodeContent, UniformDistributionParams,
};
use std::sync::Arc;

impl Uncertain<f64> {
    pub fn point(value: f64) -> Self {
        Self::from_root_node(UncertainNodeContent::Value(value.into_sampled_value()))
    }

    pub fn normal(mean: f64, std_dev: f64) -> Self {
        let params = NormalDistributionParams { mean, std_dev };
        Self::from_root_node(UncertainNodeContent::DistributionF64(
            DistributionEnum::Normal(params),
        ))
    }

    pub fn uniform(low: f64, high: f64) -> Self {
        let params = UniformDistributionParams { low, high };
        Self::from_root_node(UncertainNodeContent::DistributionF64(
            DistributionEnum::Uniform(params),
        ))
    }

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
