/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use deep_causality_data_structures::{ArrayGrid, PointIndex};
use std::hash::Hash;
use std::ops::{Add, Mul, Sub};

use crate::{Adjustable, AdjustmentError, Data, Datable, UpdateError};

impl<T> Adjustable<T> for Data<T>
where
    T: Default
        + Copy
        + Clone
        + Hash
        + Eq
        + PartialEq
        + PartialOrd
        + Add<T, Output = T>
        + Sub<T, Output = T>
        + Mul<T, Output = T>,
{
    fn update<const WIDTH: usize, const HEIGHT: usize, const DEPTH: usize, const TIME: usize>(
        &mut self,
        array_grid: &ArrayGrid<T, WIDTH, HEIGHT, DEPTH, TIME>,
    ) -> Result<(), UpdateError> {
        // Create a 1D PointIndex
        let p = PointIndex::new1d(0);

        // get the data at the index position
        let update_data = array_grid.get(p);

        // Check if the new data are okay to update
        if update_data == T::default() {
            return Err(UpdateError("Update failed, new data is ZERO".into()));
        }

        self.set_data(update_data);
        Ok(())
    }

    fn adjust<const WIDTH: usize, const HEIGHT: usize, const DEPTH: usize, const TIME: usize>(
        &mut self,
        array_grid: &ArrayGrid<T, WIDTH, HEIGHT, DEPTH, TIME>,
    ) -> Result<(), AdjustmentError> {
        // Create a 1D PointIndex
        let p = PointIndex::new1d(0);

        // get the data at the index position
        let new_data = array_grid.get(p);

        // Calculate the data adjustment
        let adjusted_data = self.get_data() + new_data;

        // Check for errors i.e. div by zero / overflow and return either an error or OK().
        if adjusted_data < T::default() {
            return Err(AdjustmentError(
                "Adjustment failed, result is a negative number".into(),
            ));
        }

        self.set_data(adjusted_data);
        Ok(())
    }
}
