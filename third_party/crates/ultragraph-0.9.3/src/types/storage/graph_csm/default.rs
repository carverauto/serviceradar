/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::CsmGraph;

impl<N, W> Default for CsmGraph<N, W>
where
    N: Clone,
    W: Clone + Default,
{
    fn default() -> Self {
        Self::new()
    }
}
