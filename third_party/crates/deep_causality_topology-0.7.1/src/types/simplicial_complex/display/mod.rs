/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Display trait implementation for SimplicialComplex.

use crate::SimplicialComplex;
use core::fmt::{Display, Formatter};

impl<T> Display for SimplicialComplex<T> {
    fn fmt(&self, f: &mut Formatter<'_>) -> core::fmt::Result {
        writeln!(f, "CausalComplex:")?;
        writeln!(f, "  Number of Skeletons: {}", self.skeletons.len())?;

        for (idx, skeleton) in self.skeletons.iter().enumerate() {
            writeln!(
                f,
                "    Skeleton {}: (Dim: {}, Num Simplices: {})",
                idx,
                skeleton.dim,
                skeleton.simplices.len()
            )?;
        }

        writeln!(
            f,
            "  Number of Boundary Operators: {}",
            self.boundary_operators.len()
        )?;
        for (idx, op) in self.boundary_operators.iter().enumerate() {
            writeln!(
                f,
                "    Boundary Operator {}: (Shape: {}x{}, Num Non-Zeros: {})",
                idx,
                op.shape().0,
                op.shape().1,
                op.values().len()
            )?;
        }

        writeln!(
            f,
            "  Number of Coboundary Operators: {}",
            self.coboundary_operators.len()
        )?;
        for (idx, op) in self.coboundary_operators.iter().enumerate() {
            writeln!(
                f,
                "    Coboundary Operator {}: (Shape: {}x{}, Num Non-Zeros: {})",
                idx,
                op.shape().0,
                op.shape().1,
                op.values().len()
            )?;
        }
        Ok(())
    }
}
