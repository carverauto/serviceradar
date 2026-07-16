/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//!
//! Trait for assumption verification used in the Model type.
//!
use crate::{Assumable, Assumption, AssumptionError, PropagatingEffect};
use std::sync::Arc;

/// Trait for types that can verify their assumptions against propagating effects.
///
/// Assumptions are verified using `PropagatingEffect<bool>` where the boolean
/// represents whether an assumption holds or not.
pub trait Transferable {
    fn get_assumptions(&self) -> &Option<Arc<Vec<Assumption>>>;

    /// Verifies the model's assumptions against a given PropagatingEffect.
    ///
    /// The function iterates through all defined assumptions and checks them against
    /// the provided data. It short-circuits and returns immediately on the first
    /// failure or error.
    ///
    /// Overwrite the default implementation if you need customization.
    ///
    /// # Arguments
    /// * `effect` - Sample data to be tested. Details on sampling should be documented in each assumption.
    ///
    /// # Returns
    /// * `Ok(())` if all assumptions hold true.
    /// * `Err(AssumptionError::AssumptionFailed(String))` if an assumption is not met.
    /// * `Err(AssumptionError::NoAssumptionsDefined)` if the model has no assumptions.
    /// * `Err(AssumptionError::NoDataToTestDefined)` if the effect slice is empty.
    /// * `Err(AssumptionError::EvaluationError(...))` if an error occurs during evaluation.
    ///
    fn verify_assumptions(&self, effect: &[PropagatingEffect<f64>]) -> Result<(), AssumptionError> {
        if effect.is_empty() {
            return Err(AssumptionError::NoDataToTestDefined);
        }

        if self.get_assumptions().is_none() {
            return Err(AssumptionError::NoAssumptionsDefined);
        }

        let assumptions = self.get_assumptions().as_ref().unwrap();

        for assumption in assumptions.iter() {
            // The `?` operator propagates any evaluation errors.
            if !assumption.verify_assumption(effect)? {
                // If an assumption returns `Ok(false)`, the check has failed.
                // We now return an error containing the specific assumption that failed.
                return Err(AssumptionError::AssumptionFailed(assumption.to_string()));
            }
        }

        // If the loop completes, all assumptions passed.
        Ok(())
    }
}
