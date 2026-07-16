/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use std::cmp::Ordering;
use std::fmt::Debug;

use crate::utils::math_utils::abs_num;
use crate::{DescriptionValue, Identifiable, NumericalValue};

/// Trait for inferable types with causal reasoning properties.
///
/// Provides properties for:
///
/// - question: Text description
/// - observation: Numerical observation value
/// - threshold: Minimum observation value
/// - effect: Expected effect value
/// - target: Target value to compare effect against
///
/// Provides methods for:
///
/// - conjoint_delta(): Estimate of unobserved factors
/// - is_inferable(): Check if inference is valid
/// - is_inverse_inferable(): Check inverse inference
///
/// Requires approximate float equality util function.
///
pub trait Inferable: Debug + Identifiable {
    fn question(&self) -> DescriptionValue;
    fn observation(&self) -> NumericalValue;
    fn threshold(&self) -> NumericalValue;
    fn effect(&self) -> NumericalValue;
    fn target(&self) -> NumericalValue;

    /// Calculates the conjoint delta for this item.
    ///
    /// The conjoint delta estimates the effect of unobserved factors.
    ///
    /// It is calculated as:
    ///
    /// 1.0 - observation
    ///
    /// Where:
    ///
    /// - observation is the numerical observation value
    ///
    /// Finally, the absolute value is taken.
    ///
    fn conjoint_delta(&self) -> NumericalValue {
        abs_num((1.0) - self.observation())
    }

    /// Checks if inference is valid for this item.
    ///
    /// Returns true if:
    ///
    /// - Observation is greater than threshold
    /// - Effect is approximately equal to target
    ///
    /// Uses 4 decimal places for float comparison.
    ///
    fn is_inferable(&self) -> bool {
        (self.observation().total_cmp(&self.threshold()) == Ordering::Greater)
            && approx_equal(self.effect(), self.target(), 4)
    }

    /// Checks if inverse inference is valid for this item.
    ///
    /// Returns true if:
    ///
    /// - Observation is less than threshold
    /// - Effect is approximately equal to target
    ///
    /// Uses 4 decimal places for float comparison.
    ///
    fn is_inverse_inferable(&self) -> bool {
        (self.observation().total_cmp(&self.threshold()) == Ordering::Less)
            && approx_equal(self.effect(), self.target(), 4)
    }
}

// Because floats vary in precision, equality is not guaranteed.
// Therefore, this comparison checks for approximate equality up to a certain number
// of decimal places.
fn approx_equal(a: f64, b: f64, decimal_places: u8) -> bool {
    let factor = 10.0f64.powi(decimal_places as i32);
    let a = (a * factor).trunc();
    let b = (b * factor).trunc();
    a == b
}

/// Trait providing reasoning methods for collections of Inferable items.
///
/// Provides methods for:
///
/// - Filtering inferable/non-inferable items
/// - Checking if all items are inferable
/// - Calculating inferability metrics
///   - conjoint_delta
///   - Counts
///   - Percentages
///
/// Requires Inferable items that implement:
///
/// - is_inferable()
/// - is_inverse_inferable()
///
/// Provides default implementations using those methods.
///
pub trait InferableReasoning<T>
where
    T: Inferable,
{
    // Compiler generated methods using macros.
    fn len(&self) -> usize;
    fn is_empty(&self) -> bool;
    fn get_all_items(&self) -> Vec<&T>;

    //
    // Default implementations.
    //

    /// Returns a vector containing all inferable items.
    ///
    /// Filters the full set of items based on is_inferable().
    ///
    fn get_all_inferable(&self) -> Vec<&T> {
        self.get_all_items()
            .into_iter()
            .filter(|i| i.is_inferable())
            .collect()
    }

    /// Returns a vector containing all inverse inferable items.
    ///
    /// Filters the full set of items based on is_inverse_inferable().
    ///
    fn get_all_inverse_inferable(&self) -> Vec<&T> {
        self.get_all_items()
            .into_iter()
            .filter(|i| i.is_inverse_inferable())
            .collect()
    }

    /// Returns a vector containing all non-inferable items.
    ///
    /// An item is non-inferable if it is both inferable and inverse inferable,
    /// which makes it undecidable.
    ///
    /// Filters the full set of items based on:
    ///
    /// - is_inferable()
    /// - is_inverse_inferable()
    ///
    fn get_all_non_inferable(&self) -> Vec<&T> {
        // must be either or, but cannot be both b/c that would be undecidable hence non-inferable
        self.get_all_items()
            .into_iter()
            .filter(|i| i.is_inferable() && i.is_inverse_inferable())
            .collect()
    }

    /// Checks if all items in the collection are inferable.
    ///
    /// Iterates through all items and checks is_inferable() on each.
    ///
    /// Returns:
    ///
    /// - true if all items are inferable
    /// - false if any item is not inferable
    ///
    fn all_inferable(&self) -> bool {
        for element in self.get_all_items() {
            if !element.is_inferable() {
                return false;
            }
        }
        true
    }

    /// Checks if all items in the collection are inverse inferable.
    ///
    /// Iterates through all items and checks is_inverse_inferable() on each.
    ///
    /// Returns:
    ///
    /// - true if all items are inverse inferable
    /// - false if any item is not inverse inferable
    ///
    fn all_inverse_inferable(&self) -> bool {
        for element in self.get_all_items() {
            if !element.is_inverse_inferable() {
                return false;
            }
        }
        true
    }

    /// Checks if all items in the collection are non-inferable.
    ///
    /// An item is non-inferable if it is both inferable and inverse inferable.
    ///
    /// Iterates through all items and checks:
    ///
    /// - is_inferable()
    /// - is_inverse_inferable()
    ///
    /// Returns:
    ///
    /// - true if any item is both inferable and inverse inferable
    /// - false if no items meet that criteria
    ///
    fn all_non_inferable(&self) -> bool {
        for element in self.get_all_items() {
            // must be either or, but cannot be both b/c that would be undecidable hence non-inferable
            if element.is_inverse_inferable() && element.is_inferable() {
                return true;
            }
        }
        false
    }

    /// Estimates the ConJointDelta for this collection.
    ///
    /// The conjoint delta represents the combined effect of
    /// unobserved factors and is used to determine the strength of the joint causal relationship.
    ///
    /// It is calculated as the difference (delta) between
    /// the combined (joint) observation (conjecture) and a theoretical 100%
    /// if the conjecture were to explain all observations, hence the name ConJointDelta:
    ///
    /// 1.0 - (sum of observations / total items)
    ///
    /// Where:
    ///
    /// - sum of observations = total items - non-inferable items
    /// - total items = length of the collection
    /// - non-inferable items = count of non-inferable items
    ///
    /// Finally, the absolute value is taken.
    ///
    ///  The resulting value is interpreted as following:
    ///
    /// Higher: THe higher the conjoint delta, the more unobserved factors are present and
    /// observed factors are not explaining the observation. Therefore, the joint causal relationship is weaker
    /// and doesn't explain much of the observation.
    ///
    /// Lower: The lower the conjoint delta, the more the observed factors explain the observation.
    /// Therefore, the joint causal relationship is stronger as it explains more of the observation.
    fn conjoint_delta(&self) -> NumericalValue {
        if self.is_empty() {
            return 1.0;
        }

        let one = 1.0;
        let total = self.len() as NumericalValue;
        let non_inferable = self.number_non_inferable();
        let cum_conjoint = total - non_inferable;

        abs_num(one - (cum_conjoint / total))
    }

    /// Counts the number of inferable items in the collection.
    ///
    /// Filters all items based on is_inferable() and returns the count.
    ///
    fn number_inferable(&self) -> NumericalValue {
        self.get_all_items()
            .into_iter()
            .filter(|i| i.is_inferable())
            .count() as NumericalValue
    }

    /// Counts the number of inverse inferable items in the collection.
    ///
    /// Filters all items based on is_inverse_inferable() and returns the count.
    ///
    fn number_inverse_inferable(&self) -> NumericalValue {
        self.get_all_items()
            .into_iter()
            .filter(|i| i.is_inverse_inferable())
            .count() as NumericalValue
    }

    /// Counts the number of non-inferable items in the collection.
    ///
    /// An item is non-inferable if it is both inferable and inverse inferable.
    ///
    /// Filters all items based on:
    ///
    /// - is_inferable()
    /// - is_inverse_inferable()
    ///
    /// And returns the count.
    ///
    fn number_non_inferable(&self) -> NumericalValue {
        self.get_all_items()
            .into_iter()
            .filter(|i| i.is_inferable() && i.is_inverse_inferable())
            .count() as NumericalValue
    }

    /// Calculates the percentage of inferable items in the collection.
    ///
    /// Divides the number of inferable items by the total length.
    /// Then multiplies by 100 to get a percentage.
    ///
    fn percent_inferable(&self) -> NumericalValue {
        if self.is_empty() {
            return 0.0;
        }

        (self.number_inferable() / self.len() as NumericalValue) * (100 as NumericalValue)
    }

    /// Calculates the percentage of inverse inferable items in the collection.
    ///
    /// Divides the number of inverse inferable items by the total length.
    /// Then multiplies by 100 to get a percentage.
    ///
    fn percent_inverse_inferable(&self) -> NumericalValue {
        if self.is_empty() {
            return 0.0;
        }

        (self.number_inverse_inferable() / self.len() as NumericalValue) * (100 as NumericalValue)
    }

    /// Calculates the percentage of non-inferable items in the collection.
    ///
    /// Divides the number of non-inferable items by the total length.
    /// Then multiplies by 100 to get a percentage.
    ///
    fn percent_non_inferable(&self) -> NumericalValue {
        if self.is_empty() {
            return 0.0;
        }

        (self.number_non_inferable() / self.len() as NumericalValue) * (100 as NumericalValue)
    }
}
