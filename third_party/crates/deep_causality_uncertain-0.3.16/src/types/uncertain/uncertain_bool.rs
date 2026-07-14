/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{
    BernoulliParams, DistributionEnum, IntoSampledValue, Uncertain, UncertainError,
    UncertainNodeContent, sprt_eval,
};

impl Uncertain<bool> {
    /// Creates a new `Uncertain<bool>` instance representing a point distribution.
    ///
    /// # Arguments
    /// * `value` - The boolean value of the point distribution.
    pub fn point(value: bool) -> Self {
        Self::from_root_node(UncertainNodeContent::Value(value.into_sampled_value()))
    }

    /// Creates a new `Uncertain<bool>` instance representing a Bernoulli distribution.
    ///
    /// # Arguments
    /// * `p` - The probability of success (true) for the Bernoulli distribution.
    pub fn bernoulli(p: f64) -> Self {
        let params = BernoulliParams { p };
        Self::from_root_node(UncertainNodeContent::DistributionBool(
            DistributionEnum::Bernoulli(params),
        ))
    }

    /// Converts the uncertain boolean distribution to a single boolean value based on statistical hypothesis testing.
    ///
    /// This method uses Sequential Probability Ratio Test (SPRT) to determine if the underlying
    /// probability of `true` exceeds a given `threshold`.
    ///
    /// # Arguments
    /// * `threshold` - The probability threshold to test against.
    /// * `confidence` - The desired confidence level (e.g., 0.95 for 95% confidence).
    /// * `epsilon` - The indifference region, defining how close the probability can be to the threshold and still be considered uncertain.
    /// * `max_samples` - The maximum number of samples to take during the SPRT.
    ///
    /// # Returns
    /// `Ok(bool)` if a decision can be made, or `Err(UncertainError)` if the test fails or cannot conclude.
    pub fn to_bool(
        &self,
        threshold: f64,
        confidence: f64,
        epsilon: f64,       // 0.05
        max_samples: usize, // 1000
    ) -> Result<bool, UncertainError> {
        // We pass sample_index 0 as the decision is based on the overall distribution, not a specific sample.
        sprt_eval::evaluate_hypothesis(self, threshold, confidence, epsilon, max_samples, 0)
    }

    /// Determines if the probability of the uncertain boolean being true exceeds a given threshold.
    ///
    /// This method is an alias for `to_bool` and also uses Sequential Probability Ratio Test (SPRT).
    ///
    /// # Arguments
    /// * `threshold` - The probability threshold to test against.
    /// * `confidence` - The desired confidence level.
    /// * `epsilon` - The indifference region.
    /// * `max_samples` - The maximum number of samples to take.
    ///
    /// # Returns
    /// `Ok(bool)` indicating whether the probability exceeds the threshold, or `Err(UncertainError)`.
    pub fn probability_exceeds(
        &self,
        threshold: f64,
        confidence: f64,
        epsilon: f64, // 0.05
        max_samples: usize,
    ) -> Result<bool, UncertainError> {
        sprt_eval::evaluate_hypothesis(self, threshold, confidence, epsilon, max_samples, 0)
    }

    /// Evaluates an implicit conditional, typically checking if the probability of true exceeds 0.5.
    ///
    /// This is a convenience method that calls `probability_exceeds` with default parameters:
    /// `threshold = 0.5`, `confidence = 0.95`, `epsilon = 0.05`, `max_samples = 1000`.
    pub fn implicit_conditional(&self) -> Result<bool, UncertainError> {
        self.probability_exceeds(0.5, 0.95, 0.05, 1000)
    }

    /// Estimates the probability that this condition is true by taking multiple samples.
    pub fn estimate_probability(&self, num_samples: usize) -> Result<f64, UncertainError> {
        let samples = self.take_samples(num_samples)?;
        if samples.is_empty() {
            Ok(0.0)
        } else {
            Ok(samples.iter().filter(|&&x| x).count() as f64 / samples.len() as f64)
        }
    }
}
