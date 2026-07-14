/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use deep_causality_data_structures::{ArrayGrid, PointIndex};

use crate::errors::{AdjustmentError, UpdateError};
use crate::{Adjustable, EntropicTime};

impl Adjustable<u64> for EntropicTime {
    fn update<const W: usize, const H: usize, const D: usize, const C: usize>(
        &mut self,
        array_grid: &ArrayGrid<u64, W, H, D, C>,
    ) -> Result<(), UpdateError> {
        // Create a 1D PointIndex
        let p = PointIndex::new1d(0);

        // get the data at the index position
        let update_time = array_grid.get(p);

        // Update the internal time to the new time
        self.entropy_tick = update_time;

        Ok(())
    }

    fn adjust<const W: usize, const H: usize, const D: usize, const C: usize>(
        &mut self,
        array_grid: &ArrayGrid<u64, W, H, D, C>,
    ) -> Result<(), AdjustmentError> {
        // Create a 1D PointIndex
        let p = PointIndex::new1d(0);

        // get the data at the index position
        let time_adjustment = array_grid.get(p);

        // Calculate checked data adjustment
        let Some(adjusted_time) = self.entropy_tick.checked_add(time_adjustment) else {
            return Err(AdjustmentError("Adjustment failed, u64 overflow".into()));
        };

        // Check if the new time is non-zero
        if time_adjustment == 0 {
            return Err(AdjustmentError(
                "Adjustment failed, new time is ZERO".into(),
            ));
        }

        // replace the internal time with the adjusted time
        self.entropy_tick = adjusted_time;

        Ok(())
    }
}
