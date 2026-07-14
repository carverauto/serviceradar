/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::SymbolicTime;
use crate::types::context_node_types::time::symbolic_time::SymbolicTimeUnit;
use std::fmt;

impl fmt::Display for SymbolicTime {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self.time {
            SymbolicTimeUnit::Before(label, t) => write!(f, "#{}, Before({label}) @ {t}", self.id),
            SymbolicTimeUnit::Named(label, t) => write!(f, "#{}, Named({label}) @ {t}", self.id),
            SymbolicTimeUnit::After(label, t) => write!(f, "#{}, After({label}) @ {t}", self.id),
            SymbolicTimeUnit::Simultaneous(labels, t) => {
                write!(f, "#{}, Simultaneous({:?}) @ {t}", self.id, labels)
            }
        }
    }
}
