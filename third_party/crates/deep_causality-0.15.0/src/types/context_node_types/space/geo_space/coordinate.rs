/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::errors::IndexError;
use crate::{Coordinate, GeoSpace};

impl Coordinate<f64> for GeoSpace {
    fn dimension(&self) -> usize {
        3
    }

    fn coordinate(&self, index: usize) -> Result<&f64, IndexError> {
        match index {
            0 => Ok(&self.lat),
            1 => Ok(&self.lon),
            2 => Ok(&self.alt),
            _ => Err(IndexError(format!(
                "Coordinate index out of bounds: {}",
                index
            ))),
        }
    }
}
