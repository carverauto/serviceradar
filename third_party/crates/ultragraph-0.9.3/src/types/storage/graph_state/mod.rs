/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

#![forbid(unsafe_code)]

use crate::{CsmGraph, DynamicGraph};

#[derive(Clone, Debug)]
pub enum GraphState<N, W>
where
    N: Clone,
    W: Clone + Default,
{
    Dynamic(DynamicGraph<N, W>), // The "unfrozen" state, for mutation
    Static(CsmGraph<N, W>),      // The "frozen" state, for analysis
}
