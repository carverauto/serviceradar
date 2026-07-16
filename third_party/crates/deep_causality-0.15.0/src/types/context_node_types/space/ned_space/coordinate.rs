/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::errors::IndexError;
use crate::{Coordinate, NedSpace};

impl Coordinate<f64> for NedSpace {
    /// Returns the number of dimensions in the coordinate system (always 3).
    fn dimension(&self) -> usize {
        3
    }

    /// Returns a reference to the coordinate value at the specified index.
    ///
    /// # Index Mapping
    /// - `0 => north`
    /// - `1 => east`
    /// - `2 => down`
    ///
    /// # Errors
    /// Returns `IndexError` if the index is out of bounds.
    ///
    fn coordinate(&self, index: usize) -> Result<&f64, IndexError> {
        match index {
            0 => Ok(&self.north),
            1 => Ok(&self.east),
            2 => Ok(&self.down),
            _ => Err(IndexError(format!(
                "Coordinate index out of bounds: {}",
                index
            ))),
        }
    }
}
