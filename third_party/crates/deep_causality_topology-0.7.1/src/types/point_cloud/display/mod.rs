/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Display implementations for PointCloud.

use crate::PointCloud;
use core::fmt::{Display, Formatter};

impl<C, D> Display for PointCloud<C, D>
where
    C: Display + Clone,
    D: Display + Clone,
{
    fn fmt(&self, f: &mut Formatter<'_>) -> core::fmt::Result {
        writeln!(f, "PointCloud:")?;
        writeln!(f, "  Number of Points: {}", self.len())?;
        writeln!(
            f,
            "  Point Dimensions: {}",
            self.points.shape().get(1).unwrap_or(&0)
        )?;
        writeln!(f, "  Points Data: {}", self.points)?;
        writeln!(f, "  Metadata Data: {}", self.metadata)?;
        Ok(())
    }
}
