/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::errors::{AdjustmentError, UpdateError};
use crate::{Adjustable, EuclideanSpace};
use deep_causality_data_structures::{ArrayGrid, PointIndex};

impl Adjustable<f64> for EuclideanSpace {
    fn update<const WIDTH: usize, const HEIGHT: usize, const DEPTH: usize, const TIME: usize>(
        &mut self,
        array_grid: &ArrayGrid<f64, WIDTH, HEIGHT, DEPTH, TIME>,
    ) -> Result<(), UpdateError> {
        // Create a 3D PointIndex for each of the updated x,y,z coordinates
        let p1 = PointIndex::new3d(0, 0, 0);
        let p2 = PointIndex::new3d(0, 0, 1);
        let p3 = PointIndex::new3d(0, 0, 2);

        // get the data at the index position
        let new_x = array_grid.get(p1);
        let new_y = array_grid.get(p2);
        let new_z = array_grid.get(p3);

        // Check if the adjusted data are safe to update i.e. not greater than max f64 value
        if !new_x.is_finite() {
            return Err(UpdateError(
                "Update failed, new X value is not finite".into(),
            ));
        }

        if !new_y.is_finite() {
            return Err(UpdateError(
                "Update failed, new Y value is not finite".into(),
            ));
        }

        if !new_z.is_finite() {
            return Err(UpdateError(
                "Update failed, new Z value is not finite".into(),
            ));
        }

        // Update the internal data
        self.x = new_x;
        self.y = new_y;
        self.z = new_z;

        Ok(())
    }

    fn adjust<const WIDTH: usize, const HEIGHT: usize, const DEPTH: usize, const TIME: usize>(
        &mut self,
        array_grid: &ArrayGrid<f64, WIDTH, HEIGHT, DEPTH, TIME>,
    ) -> Result<(), AdjustmentError> {
        // Create a 3D PointIndex for each of the updated x,y,z coordinates
        let p1 = PointIndex::new3d(0, 0, 0);
        let p2 = PointIndex::new3d(0, 0, 1);
        let p3 = PointIndex::new3d(0, 0, 2);

        // Get the data at the index position from the array grid
        let new_x = array_grid.get(p1);
        let new_y = array_grid.get(p2);
        let new_z = array_grid.get(p3);

        // Calculate the adjusted data by adding the new data to the current data
        let adjusted_x = self.x + new_x;
        let adjusted_y = self.y + new_y;
        let adjusted_z = self.z + new_z;

        // Check if the adjusted data are safe to update i.e. not greater than max f64 value
        if !adjusted_x.is_finite() {
            return Err(AdjustmentError(
                "Adjustment failed, new X value is not finite".into(),
            ));
        }

        if !adjusted_y.is_finite() {
            return Err(AdjustmentError(
                "Adjustment failed, new Y value is not finite".into(),
            ));
        }

        if !adjusted_z.is_finite() {
            return Err(AdjustmentError(
                "Adjustment failed, new Z value is not finite".into(),
            ));
        }

        // Update the internal data
        self.x = adjusted_x;
        self.y = adjusted_y;
        self.z = adjusted_z;

        Ok(())
    }
}
