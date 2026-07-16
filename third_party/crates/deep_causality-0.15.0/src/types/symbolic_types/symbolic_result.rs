/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use std::fmt::Display;

#[derive(Debug, Copy, Clone, Eq, PartialEq, Hash)]
pub enum SymbolicResult {
    Proven,
    Disproven,
    Undetermined,
}

impl Display for SymbolicResult {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SymbolicResult::Proven => write!(f, "Proven"),
            SymbolicResult::Disproven => write!(f, "Disproven"),
            SymbolicResult::Undetermined => write!(f, "Undetermined"),
        }
    }
}
