/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use std::fmt::Debug;

use crate::{Identifiable, NumericalValue};

/// Observable trait for objects that can be observed.
///
/// Requires:
///
/// - Debug - for debug printing
/// - Identifiable - for unique identification
///
/// Provides methods:
///
/// - observation() - gets the numerical observation value
/// - observed_effect() - gets the observed effect value
/// - effect_observed() - checks if observation meets threshold and matches effect
///
/// effect_observed() checks:
///
/// - observation >= target_threshold
/// - observed_effect == target_effect
///
pub trait Observable: Debug + Identifiable {
    fn observation(&self) -> NumericalValue;
    fn observed_effect(&self) -> NumericalValue;

    /// Checks if the observed effect meets the target threshold and effect.
    ///
    /// Returns true if:
    ///
    /// - observation() >= target_threshold
    /// - observed_effect() == target_effect
    ///
    /// Otherwise returns false.
    ///
    fn effect_observed(
        &self,
        target_threshold: NumericalValue,
        target_effect: NumericalValue,
    ) -> bool {
        (self.observation() >= target_threshold) && (self.observed_effect() == target_effect)
    }
}

/// ObservableReasoning trait provides reasoning methods for collections of Observable items.
///
/// Where T: Observable
///
/// Provides methods:
///
/// - len() - number of items
/// - is_empty() - checks if empty
/// - get_all_items() - returns all items
///
/// - number_observation() - counts items meeting threshold and effect
/// - number_non_observation() - counts items not meeting criteria
/// - percent_observation() - % of items meeting criteria
/// - percent_non_observation() - % of items not meeting criteria
///
/// Uses T's effect_observed() method to check criteria.
///
pub trait ObservableReasoning<T>
where
    T: Observable,
{
    // Compiler generated methods using macros.
    fn len(&self) -> usize;
    fn is_empty(&self) -> bool;
    fn get_all_items(&self) -> Vec<&T>;

    //
    // Default implementations.
    //

    /// Counts the number of observations meeting the criteria.
    ///
    /// Iterates through all items and filters based on:
    ///
    /// - item.effect_observed(target_threshold, target_effect)
    ///
    /// Then returns the count.
    ///
    fn number_observation(
        &self,
        target_threshold: NumericalValue,
        target_effect: NumericalValue,
    ) -> NumericalValue {
        self.get_all_items()
            .iter()
            .filter(|o| o.effect_observed(target_threshold, target_effect))
            .count() as NumericalValue
    }

    /// Counts the number of non-observations based on the criteria.
    ///
    /// Calculates this by:
    ///
    /// - self.len() - total number of items
    /// - minus number_observation() count
    ///
    /// Returns the number of items not meeting criteria.
    ///
    fn number_non_observation(
        &self,
        target_threshold: NumericalValue,
        target_effect: NumericalValue,
    ) -> NumericalValue {
        self.len() as NumericalValue - self.number_observation(target_threshold, target_effect)
    }

    /// Calculates the percentage of observations meeting the criteria.
    ///
    /// Divides the number_observation count by the total number of items.
    ///
    /// Returns value between 0.0 and 1.0 as a percentage.
    ///
    fn percent_observation(
        &self,
        target_threshold: NumericalValue,
        target_effect: NumericalValue,
    ) -> NumericalValue {
        if self.is_empty() {
            return 0.0;
        }

        self.number_observation(target_threshold, target_effect) / self.len() as NumericalValue
    }

    /// Calculates the percentage of non-observations based on the criteria.
    ///
    /// Returns 1.0 minus the percent_observation.
    ///
    fn percent_non_observation(
        &self,
        target_threshold: NumericalValue,
        target_effect: NumericalValue,
    ) -> NumericalValue {
        1.0 - self.percent_observation(target_threshold, target_effect)
    }
}
