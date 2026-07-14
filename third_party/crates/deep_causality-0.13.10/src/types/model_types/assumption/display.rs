/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::Assumption;
use std::fmt::{Display, Formatter};

impl Display for Assumption {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        write!(
            // Delegate to debug
            f,
            "{self:?}"
        )
    }
}
