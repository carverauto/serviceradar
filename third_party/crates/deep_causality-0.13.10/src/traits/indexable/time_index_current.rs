/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{TimeIndexable, TimeScale};

pub trait CurrentTimeIndex: TimeIndexable {
    /// Get the current year index.
    ///
    /// # Returns
    ///
    /// The current year index as a `usize`.
    ///
    fn get_current_year_index(&self) -> Option<&usize> {
        let key = TimeScale::Year as usize;
        self.get_time_index(&key, true)
    }

    /// Get the current month index.
    ///
    /// # Returns
    ///
    /// The current month index as a `usize`.
    ///
    fn get_current_month_index(&self) -> Option<&usize> {
        let key = TimeScale::Month as usize;
        self.get_time_index(&key, true)
    }

    /// Get the current week index.
    ///
    /// # Returns
    ///
    /// The current week index as a `usize`.
    ///
    fn get_current_week_index(&self) -> Option<&usize> {
        let key = TimeScale::Week as usize;
        self.get_time_index(&key, true)
    }

    /// Get the current day index.
    ///
    /// # Returns
    ///
    /// The current day index as a `usize`.
    ///
    fn get_current_day_index(&self) -> Option<&usize> {
        let key = TimeScale::Day as usize;
        self.get_time_index(&key, true)
    }

    /// Get the current hour index.
    ///
    /// # Returns
    ///
    /// The current hour index as a `usize`.
    ///
    fn get_current_hour_index(&self) -> Option<&usize> {
        let key = TimeScale::Hour as usize;
        self.get_time_index(&key, true)
    }

    /// Get the current minute index.
    ///
    /// # Returns
    ///
    /// The current minute index as a `usize`.
    ///
    fn get_current_minute_index(&self) -> Option<&usize> {
        let key = TimeScale::Minute as usize;
        self.get_time_index(&key, true)
    }

    /// Set the current year index.
    ///
    /// # Parameters
    ///
    /// * `index` - The year index to set as a `usize`
    ///
    fn set_current_year_index(&mut self, index: usize) {
        let key = TimeScale::Year as usize;
        self.set_time_index(key, index, true)
    }

    /// Set the current month index.
    ///
    /// # Parameters
    ///
    /// * `index` - The month index to set as a `usize`
    ///
    fn set_current_month_index(&mut self, index: usize) {
        let key = TimeScale::Month as usize;
        self.set_time_index(key, index, true)
    }

    /// Set the current week index.
    ///
    /// # Parameters
    ///
    /// * `index` - The week index to set as a `usize`
    ///
    fn set_current_week_index(&mut self, index: usize) {
        let key = TimeScale::Week as usize;
        self.set_time_index(key, index, true)
    }

    /// Set the current day index.
    ///
    /// # Parameters
    ///
    /// * `index` - The day index to set as a `usize`
    ///
    fn set_current_day_index(&mut self, index: usize) {
        let key = TimeScale::Day as usize;
        self.set_time_index(key, index, true)
    }

    /// Set the current hour index.
    ///
    /// # Parameters
    ///
    /// * `index` - The hour index to set as a `usize`
    ///
    fn set_current_hour_index(&mut self, index: usize) {
        let key = TimeScale::Hour as usize;
        self.set_time_index(key, index, true)
    }

    /// Set the current minute index.
    ///
    /// # Parameters
    ///
    /// * `index` - The minute index to set as a `usize`
    ///
    fn set_current_minute_index(&mut self, index: usize) {
        let key = TimeScale::Minute as usize;
        self.set_time_index(key, index, true)
    }
}
