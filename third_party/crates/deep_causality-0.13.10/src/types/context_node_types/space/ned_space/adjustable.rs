/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::errors::{AdjustmentError, UpdateError};
use crate::{Adjustable, NedSpace};
use deep_causality_data_structures::{ArrayGrid, PointIndex};

impl Adjustable<f64> for NedSpace {
    fn update<const W: usize, const H: usize, const D: usize, const C: usize>(
        &mut self,
        array_grid: &ArrayGrid<f64, W, H, D, C>,
    ) -> Result<(), UpdateError> {
        // Create a 3D PointIndex for each of the updated x,y,z coordinates
        let p1 = PointIndex::new3d(0, 0, 0);
        let p2 = PointIndex::new3d(0, 0, 1);
        let p3 = PointIndex::new3d(0, 0, 2);

        // Get the data at the index position from the array grid
        let new_north = array_grid.get(p1);
        let new_east = array_grid.get(p2);
        let new_down = array_grid.get(p3);

        // Check if the adjusted data are safe to update i.e. not greater than max f64 value
        if !new_north.is_finite() {
            return Err(UpdateError(
                "Update failed, new north value is not finite".into(),
            ));
        }

        if !new_east.is_finite() {
            return Err(UpdateError(
                "Update failed, new east value is not finite".into(),
            ));
        }

        if !new_down.is_finite() {
            return Err(UpdateError(
                "Update failed, new down value is not finite".into(),
            ));
        }

        // Replace the internal data with the new data
        self.north = new_north;
        self.east = new_east;
        self.down = new_down;

        Ok(())
    }

    fn adjust<const W: usize, const H: usize, const D: usize, const C: usize>(
        &mut self,
        array_grid: &ArrayGrid<f64, W, H, D, C>,
    ) -> Result<(), AdjustmentError> {
        // Create a 3D PointIndex for each of the updated x,y,z coordinates
        let p1 = PointIndex::new3d(0, 0, 0);
        let p2 = PointIndex::new3d(0, 0, 1);
        let p3 = PointIndex::new3d(0, 0, 2);

        // Get the data at the index position from the array grid
        let new_north = array_grid.get(p1);
        let new_east = array_grid.get(p2);
        let new_down = array_grid.get(p3);

        // Calculate the adjusted data by adding the new data to the current data
        let adjusted_north = self.north + new_north;
        let adjusted_east = self.east + new_east;
        let adjusted_down = self.down + new_down;

        // Check if the adjusted data are safe to update i.e. not greater than max f64 value
        if !adjusted_north.is_finite() {
            return Err(AdjustmentError(
                "Adjustment failed, new north value is not finite".into(),
            ));
        }

        if !adjusted_east.is_finite() {
            return Err(AdjustmentError(
                "Adjustment failed, new east value is not finite".into(),
            ));
        }

        if !adjusted_down.is_finite() {
            return Err(AdjustmentError(
                "Adjustment failed, new down value is not finite".into(),
            ));
        }

        // Update the internal data with the adjusted data
        self.north = adjusted_north;
        self.east = adjusted_east;
        self.down = adjusted_down;

        Ok(())
    }
}
