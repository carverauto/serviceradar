/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::errors::{AdjustmentError, UpdateError};
use deep_causality_data_structures::ArrayGrid;

pub trait Adjustable<T>
where
    T: Copy + Default,
{
    /// The default implementation does nothing to keep update optional.
    /// Override this method to implement a node update when needed.
    /// For a sample implementation, see src/types/context_types/node_types_adjustable
    fn update<const WIDTH: usize, const HEIGHT: usize, const DEPTH: usize, const TIME: usize>(
        &mut self,
        _array_grid: &ArrayGrid<T, WIDTH, HEIGHT, DEPTH, TIME>,
    ) -> Result<(), UpdateError> {
        Ok(())
    }

    /// The default implementation does nothing to keep adjustment optional.
    /// Override this method to implement a node adjustment when needed.
    /// Depending on the type of node adjustment, select a 1, 2,3, or 4 dimensional array grid
    /// that contains the transformation data to apply to the node.
    /// For a sample implementation, see src/types/context_types/node_types_adjustable
    fn adjust<const WIDTH: usize, const HEIGHT: usize, const DEPTH: usize, const TIME: usize>(
        &mut self,
        _array_grid: &ArrayGrid<T, WIDTH, HEIGHT, DEPTH, TIME>,
    ) -> Result<(), AdjustmentError> {
        Ok(())
    }
}

pub trait UncertainAdjustable {
    type Data;

    fn update(&mut self, _uncertain: Self::Data) -> Result<(), AdjustmentError> {
        Ok(())
    }

    fn adjust(&mut self, _uncertain: Self::Data) -> Result<(), AdjustmentError> {
        Ok(())
    }
}
