/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::DynamicGraph;

impl<N, W> Default for DynamicGraph<N, W> {
    fn default() -> Self {
        Self::new()
    }
}
