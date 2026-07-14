/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{TimeIndexable, TimeScale};

/// Trait for getting and setting the previous time index for various time scales.
///
/// This trait extends `TimeIndexable` and provides a convenient interface for interacting
/// with the "previous" time indices, as opposed to the "current" ones.
pub trait PreviousTimeIndex: TimeIndexable {
    /// Returns the previous year index, if it exists.
    ///
    /// # Returns
    ///
    /// An `Option` containing a reference to the index, or `None` if not set.
    fn get_previous_year_index(&self) -> Option<&usize> {
        let key = TimeScale::Year as usize;
        self.get_time_index(&key, false)
    }

    /// Returns the previous month index, if it exists.
    ///
    /// # Returns
    ///
    /// An `Option` containing a reference to the index, or `None` if not set.
    fn get_previous_month_index(&self) -> Option<&usize> {
        let key = TimeScale::Month as usize;
        self.get_time_index(&key, false)
    }

    /// Returns the previous week index, if it exists.
    ///
    /// # Returns
    ///
    /// An `Option` containing a reference to the index, or `None` if not set.
    fn get_previous_week_index(&self) -> Option<&usize> {
        let key = TimeScale::Week as usize;
        self.get_time_index(&key, false)
    }

    /// Returns the previous day index, if it exists.
    ///
    /// # Returns
    ///
    /// An `Option` containing a reference to the index, or `None` if not set.
    fn get_previous_day_index(&self) -> Option<&usize> {
        let key = TimeScale::Day as usize;
        self.get_time_index(&key, false)
    }

    /// Returns the previous hour index, if it exists.
    ///
    /// # Returns
    ///
    /// An `Option` containing a reference to the index, or `None` if not set.
    fn get_previous_hour_index(&self) -> Option<&usize> {
        let key = TimeScale::Hour as usize;
        self.get_time_index(&key, false)
    }

    /// Returns the previous minute index, if it exists.
    ///
    /// # Returns
    ///
    /// An `Option` containing a reference to the index, or `None` if not set.
    fn get_previous_minute_index(&self) -> Option<&usize> {
        let key = TimeScale::Minute as usize;
        self.get_time_index(&key, false)
    }

    /// Sets the previous year index.
    ///
    /// # Arguments
    ///
    /// * `index` - The index to set for the previous year.
    fn set_previous_year_index(&mut self, index: usize) {
        let key = TimeScale::Year as usize;
        self.set_time_index(key, index, false)
    }

    /// Sets the previous month index.
    ///
    /// # Arguments
    ///
    /// * `index` - The index to set for the previous month.
    fn set_previous_month_index(&mut self, index: usize) {
        let key = TimeScale::Month as usize;
        self.set_time_index(key, index, false)
    }

    /// Sets the previous week index.
    ///
    /// # Arguments
    ///
    /// * `index` - The index to set for the previous week.
    fn set_previous_week_index(&mut self, index: usize) {
        let key = TimeScale::Week as usize;
        self.set_time_index(key, index, false)
    }

    /// Sets the previous day index.
    ///
    /// # Arguments
    ///
    /// * `index` - The index to set for the previous day.
    fn set_previous_day_index(&mut self, index: usize) {
        let key = TimeScale::Day as usize;
        self.set_time_index(key, index, false)
    }

    /// Sets the previous hour index.
    ///
    /// # Arguments
    ///
    /// * `index` - The index to set for the previous hour.
    fn set_previous_hour_index(&mut self, index: usize) {
        let key = TimeScale::Hour as usize;
        self.set_time_index(key, index, false)
    }

    /// Sets the previous minute index.
    ///
    /// # Arguments
    ///
    /// * `index` - The index to set for the previous minute.
    fn set_previous_minute_index(&mut self, index: usize) {
        let key = TimeScale::Minute as usize;
        self.set_time_index(key, index, false)
    }
}
