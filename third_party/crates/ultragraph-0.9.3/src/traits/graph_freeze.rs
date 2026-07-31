/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::CsmGraph;

pub trait Freezable<N, W>
where
    N: Clone,
    W: Clone + Default,
{
    fn freeze(self) -> CsmGraph<N, W>;
}
