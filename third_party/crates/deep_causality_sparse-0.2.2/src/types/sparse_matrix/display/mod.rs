/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::CsrMatrix;
use deep_causality_num::Zero;
use std::fmt::Display;

impl<T> Display for CsrMatrix<T>
where
    T: Display + Copy + Zero + PartialEq, // Added Zero and PartialEq for get_value_at
{
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let (rows, cols) = self.shape;
        if rows == 0 || cols == 0 {
            return write!(f, "CsrMatrix ({}x{}) [Empty]", rows, cols);
        }

        writeln!(f, "CsrMatrix ({}x{})", rows, cols)?;

        for r_idx in 0..rows {
            write!(f, "[")?;
            for c_idx in 0..cols {
                let value = self.get_value_at(r_idx, c_idx);
                write!(f, "{: >8.3}", value)?; // Pad for alignment, and format to 3 decimal places
                if c_idx < cols - 1 {
                    write!(f, ", ")?;
                }
            }
            writeln!(f, "]")?;
        }
        Ok(())
    }
}
