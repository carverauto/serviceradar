/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Display implementations for Topology.

use crate::Topology;
use core::fmt::{Display, Formatter};

impl<T> Display for Topology<T>
where
    T: Display + Clone,
{
    fn fmt(&self, f: &mut Formatter<'_>) -> core::fmt::Result {
        writeln!(f, "CausalTopology:")?;
        writeln!(f, "  Grade: {}", self.grade)?;
        writeln!(f, "  Cursor: {}", self.cursor)?;
        writeln!(f, "  Data: {}", self.data)?;
        // For now, let's omit detailed complex info in Display.
        Ok(())
    }
}
