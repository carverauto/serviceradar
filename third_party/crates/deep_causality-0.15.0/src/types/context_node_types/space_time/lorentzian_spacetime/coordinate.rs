/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::errors::IndexError;
use crate::{Coordinate, LorentzianSpacetime};

impl Coordinate<f64> for LorentzianSpacetime {
    /// Returns the number of dimensions in the coordinate system (always 4).l
    fn dimension(&self) -> usize {
        4
    }

    /// Returns a reference to the coordinate value at the specified index.
    ///
    /// # Index Mapping
    /// - `0 => x`
    /// - `1 => y`
    /// - `2 => z`
    /// - `3 => t`
    ///
    /// # Errors
    /// Returns `IndexError` if the index is out of bounds.
    ///
    fn coordinate(&self, index: usize) -> Result<&f64, IndexError> {
        match index {
            0 => Ok(&self.x),
            1 => Ok(&self.y),
            2 => Ok(&self.z),
            3 => Ok(&self.t),
            _ => Err(IndexError(format!(
                "Coordinate index out of bounds: {}",
                index
            ))),
        }
    }
}
