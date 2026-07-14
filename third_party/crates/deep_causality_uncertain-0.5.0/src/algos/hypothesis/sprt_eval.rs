/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{Uncertain, UncertainError};

/// Implements the Sequential Probability Ratio Test (SPRT) to evaluate a hypothesis
/// about an uncertain boolean value.
///
/// H0: P(true) <= threshold - epsilon
/// H1: P(true) > threshold + epsilon
///
/// Returns `true` if H1 is accepted, `false` if H0 is accepted.
///
/// # Parameters
/// - `uncertain_bool`: The `Uncertain<bool>` value to test.
/// - `threshold`: The probability threshold to test against (e.g., 0.5 for "more likely than not").
/// - `confidence`: The desired confidence level (e.g., 0.95).
/// - `epsilon`: The indifference region. Samples within `threshold +/- epsilon` are inconclusive.
/// - `max_samples`: The maximum number of samples to draw before making a fallback decision.
pub fn evaluate_hypothesis(
    uncertain_bool: &Uncertain<bool>,
    threshold: f64,
    confidence: f64,
    epsilon: f64,
    max_samples: usize,
    initial_sample_index: u64,
) -> Result<bool, UncertainError> {
    // Set alpha and beta for the test
    let alpha_error = 1.0 - confidence; // Type I error (false positive rate)
    let beta_error = alpha_error; // Type II error (false negative rate), often set equal to alpha

    // Calculate SPRT boundaries
    // Avoid log(0) by clamping probabilities
    let a_boundary = (beta_error / (1.0 - alpha_error)).ln();
    let b_boundary = ((1.0 - beta_error) / alpha_error).ln();

    // Set indifference region (p0 and p1)
    let p0 = (threshold - epsilon).clamp(0.0, 1.0 - f64::EPSILON); // Null hypothesis probability
    let p1 = (threshold + epsilon).clamp(f64::EPSILON, 1.0); // Alternative hypothesis probability

    let mut successes = 0;
    let mut samples_drawn = 0;

    // Batch sampling (as per paper, but simplified for now)
    let batch_size = 10;

    while samples_drawn < max_samples {
        let current_batch_size = (batch_size).min(max_samples - samples_drawn);
        if current_batch_size == 0 {
            break;
        } // Avoid infinite loop if max_samples is reached

        for _ in 0..current_batch_size {
            let sample_result =
                uncertain_bool.sample_with_index(initial_sample_index + samples_drawn as u64)?; // Get a sample
            if sample_result {
                successes += 1;
            }
            samples_drawn += 1;
        }

        // Compute log-likelihood ratio (LLR)
        let n = samples_drawn as f64;
        let x = successes as f64;

        // Avoid log(0) or log(negative)
        let term1 = if p1 > f64::EPSILON && p0 > f64::EPSILON {
            (p1 / p0).ln()
        } else {
            0.0
        };
        let term2 = if (1.0 - p1) > f64::EPSILON && (1.0 - p0) > f64::EPSILON {
            ((1.0 - p1) / (1.0 - p0)).ln()
        } else {
            0.0
        };

        let llr = x * term1 + (n - x) * term2;

        if llr <= a_boundary {
            // Accept H0: P(true) <= threshold
            return Ok(false);
        } else if llr >= b_boundary {
            // Accept H1: P(true) > threshold
            return Ok(true);
        }
    }

    // Fallback decision if max_samples reached without clear conclusion
    let final_p = successes as f64 / samples_drawn as f64;
    Ok(final_p > threshold)
}
