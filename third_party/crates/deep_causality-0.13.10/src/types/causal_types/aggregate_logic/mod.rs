/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use std::fmt::{Display, Formatter};

/// Defines how the results from a collection of `Causable` items should be aggregated.
#[derive(Debug, Copy, Clone, Eq, PartialEq, Hash)]
pub enum AggregateLogic {
    /// Returns true only if all members evaluate to a propagating effect.
    All,
    /// Returns true if at least one member evaluates to a propagating effect.
    Any,
    /// Returns true only if none of the members evaluate to a propagating effect.
    None,
    /// Returns true if at least k members evaluate to a propagating effect.
    Some(usize),
}

impl Display for AggregateLogic {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
