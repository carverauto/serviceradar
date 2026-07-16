/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{SymbolicTime, SymbolicTimeUnit, Temporal, TimeScale};

impl Temporal<i64> for SymbolicTime {
    fn time_scale(&self) -> TimeScale {
        TimeScale::Symbolic
    }

    fn time_unit(&self) -> i64 {
        match &self.time {
            SymbolicTimeUnit::Before(_, t)
            | SymbolicTimeUnit::Named(_, t)
            | SymbolicTimeUnit::After(_, t)
            | SymbolicTimeUnit::Simultaneous(_, t) => *t,
        }
    }
}
