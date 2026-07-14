/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{Adjustable, AdjustmentError, TangentSpacetime, UpdateError};
use deep_causality_data_structures::{ArrayGrid, PointIndex};

/// Updates the position of the TangentSpacetime node.
/// The metric tensor is updated via the 'update_metric_tensor' method.
impl Adjustable<f64> for TangentSpacetime {
    fn update<const W: usize, const H: usize, const D: usize, const C: usize>(
        &mut self,
        array_grid: &ArrayGrid<f64, W, H, D, C>,
    ) -> Result<(), UpdateError> {
        // Create a 3D PointIndex for each of the updated x,y,z coordinates
        let p1 = PointIndex::new3d(0, 0, 0);
        let p2 = PointIndex::new3d(0, 0, 1);
        let p3 = PointIndex::new3d(0, 0, 2);
        let p4 = PointIndex::new3d(0, 0, 3);

        // Get the data at the index position from the array grid
        let new_x = array_grid.get(p1);
        let new_y = array_grid.get(p2);
        let new_z = array_grid.get(p3);
        let new_t = array_grid.get(p4);

        if !new_x.is_finite() {
            return Err(UpdateError(
                "Update failed, new X is not a finite value".into(),
            ));
        }

        if !new_y.is_finite() {
            return Err(UpdateError(
                "Update failed, new Y is not a finite value".into(),
            ));
        }

        if !new_z.is_finite() {
            return Err(UpdateError(
                "Update failed, new Z is not a finite value".into(),
            ));
        }

        if !new_t.is_finite() {
            return Err(UpdateError(
                "Update failed, new T is not a finite value".into(),
            ));
        }

        // Replace the internal data with the new data
        self.x = new_x;
        self.y = new_y;
        self.z = new_z;
        self.t = new_t;

        Ok(())
    }

    /// Adjust the position of the TangentSpacetime node.
    /// The metric tensor is updated via the 'update_metric_tensor' method.
    fn adjust<const W: usize, const H: usize, const D: usize, const C: usize>(
        &mut self,
        array_grid: &ArrayGrid<f64, W, H, D, C>,
    ) -> Result<(), AdjustmentError> {
        // Create a 3D PointIndex for each of the updated x,y,z coordinates
        let p1 = PointIndex::new3d(0, 0, 0);
        let p2 = PointIndex::new3d(0, 0, 1);
        let p3 = PointIndex::new3d(0, 0, 2);
        let p4 = PointIndex::new3d(0, 0, 3);

        // get the data at the index position
        let new_x = array_grid.get(p1);
        let new_y = array_grid.get(p2);
        let new_z = array_grid.get(p3);
        let new_t = array_grid.get(p4);

        // Calculate the adjusted data by adding the new data to the current data
        let adjusted_x = self.x + new_x;
        let adjusted_y = self.y + new_y;
        let adjusted_z = self.z + new_z;
        let adjusted_t = self.t + new_t;

        // Check if the adjusted data are safe to update i.e. not greater than max f64 value
        if !adjusted_x.is_finite() {
            return Err(AdjustmentError(
                "Adjustment failed, adjusted x value is not finite".into(),
            ));
        }

        if !adjusted_y.is_finite() {
            return Err(AdjustmentError(
                "Adjustment failed, adjusted Y value is not finite".into(),
            ));
        }

        if !adjusted_z.is_finite() {
            return Err(AdjustmentError(
                "Adjustment failed, adjusted z value is not finite".into(),
            ));
        }

        if !adjusted_t.is_finite() {
            return Err(AdjustmentError(
                "Adjustment failed, adjusted t value is not finite".into(),
            ));
        }

        // Update the internal data with the adjusted data
        self.x = adjusted_x;
        self.y = adjusted_y;
        self.z = adjusted_z;
        self.t = adjusted_t;

        Ok(())
    }
}
