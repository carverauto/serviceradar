/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use deep_causality_data_structures::{ArrayGrid, PointIndex};

use crate::errors::{AdjustmentError, UpdateError};
use crate::{Adjustable, EuclideanTime};

impl Adjustable<f64> for EuclideanTime {
    fn update<const W: usize, const H: usize, const D: usize, const C: usize>(
        &mut self,
        array_grid: &ArrayGrid<f64, W, H, D, C>,
    ) -> Result<(), UpdateError> {
        // Create a 1D PointIndex
        let p = PointIndex::new1d(0);

        // get the data at the index position
        let update_time = array_grid.get(p);

        // Update the internal time to the new time
        self.time_unit = update_time;

        Ok(())
    }

    fn adjust<const W: usize, const H: usize, const D: usize, const C: usize>(
        &mut self,
        array_grid: &ArrayGrid<f64, W, H, D, C>,
    ) -> Result<(), AdjustmentError> {
        // Create a 1D PointIndex
        let p = PointIndex::new1d(0);

        // get the data at the index position
        let time_adjustment = array_grid.get(p);

        if time_adjustment.is_nan() {
            return Err(AdjustmentError("Adjustment failed, time is NaN".into()));
        }

        // Check if the new time is non-negative. Unless you want to go back in time...
        if time_adjustment < f64::default() {
            return Err(AdjustmentError(
                "Adjustment failed, new time is NEGATIVE".into(),
            ));
        }

        // Calculate the data adjustment
        let adjusted_time = self.time_unit + time_adjustment;

        // Reject non-finite results (NaN, ±inf)
        if !adjusted_time.is_finite() {
            return Err(AdjustmentError(
                "Adjustment failed, result is not finite (NaN or Inf)".into(),
            ));
        }

        // Check if the new time is non-zero
        if adjusted_time == f64::default() {
            return Err(AdjustmentError(
                "Adjustment failed, new time is ZERO".into(),
            ));
        }

        // replace the internal time with the adjusted time
        self.time_unit = adjusted_time;

        Ok(())
    }
}
