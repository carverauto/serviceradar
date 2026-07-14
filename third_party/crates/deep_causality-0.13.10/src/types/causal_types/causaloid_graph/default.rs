/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{CausaloidGraph, CausaloidId};

impl Default for CausaloidGraph<CausaloidId> {
    fn default() -> Self {
        Self::new(0)
    }
}
