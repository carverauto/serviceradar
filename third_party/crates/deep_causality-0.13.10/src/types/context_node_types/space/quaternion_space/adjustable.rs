/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::errors::{AdjustmentError, UpdateError};
use crate::{Adjustable, QuaternionSpace};
use deep_causality_data_structures::{ArrayGrid, PointIndex};

impl Adjustable<f64> for QuaternionSpace {
    fn update<const W: usize, const H: usize, const D: usize, const C: usize>(
        &mut self,
        array_grid: &ArrayGrid<f64, W, H, D, C>,
    ) -> Result<(), UpdateError> {
        // Create a 4D PointIndex for each of the updated x,y,z coordinates
        let p1 = PointIndex::new4d(0, 0, 0, 0);
        let p2 = PointIndex::new4d(0, 0, 0, 1);
        let p3 = PointIndex::new4d(0, 0, 0, 2);
        let p4 = PointIndex::new4d(0, 0, 0, 3);

        // The quaternion representing the rotation in [w, x, y, z] order

        // Get the data at the index position
        let new_w = array_grid.get(p1);
        let new_x = array_grid.get(p2);
        let new_y = array_grid.get(p3);
        let new_z = array_grid.get(p4);

        // Check if the adjusted data are safe to update i.e. not greater than max f64 value
        if !new_w.is_finite() {
            return Err(UpdateError(
                "Update failed, new X value is not finite".into(),
            ));
        }

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
        self.w = new_w;
        self.x = new_x;
        self.y = new_y;
        self.z = new_z;

        Ok(())
    }

    fn adjust<const W: usize, const H: usize, const D: usize, const C: usize>(
        &mut self,
        array_grid: &ArrayGrid<f64, W, H, D, C>,
    ) -> Result<(), AdjustmentError> {
        // Create a 4D PointIndex for each of the updated x,y,z, t quaternion coordinates
        let p1 = PointIndex::new4d(0, 0, 0, 0);
        let p2 = PointIndex::new4d(0, 0, 0, 1);
        let p3 = PointIndex::new4d(0, 0, 0, 2);
        let p4 = PointIndex::new4d(0, 0, 0, 3);

        // Get the data at the index position
        let new_w = array_grid.get(p1);
        let new_x = array_grid.get(p2);
        let new_y = array_grid.get(p3);
        let new_z = array_grid.get(p4);

        // Calculate the adjusted data by adding the new data to the current data
        let adjusted_w = self.w + new_w;
        let adjusted_x = self.x + new_x;
        let adjusted_y = self.y + new_y;
        let adjusted_z = self.z + new_z;

        // Check if the adjusted data are safe to update i.e. not greater than max f64 value
        if !adjusted_w.is_finite() {
            return Err(AdjustmentError(
                "Adjustment failed, new W value is not finite".into(),
            ));
        }

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
        self.w = adjusted_w;
        self.x = adjusted_x;
        self.y = adjusted_y;
        self.z = adjusted_z;

        Ok(())
    }
}
