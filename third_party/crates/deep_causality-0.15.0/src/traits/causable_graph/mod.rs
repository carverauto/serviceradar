/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use ultragraph::UltraGraphWeighted;

pub mod graph;
pub mod graph_reasoning;

// Type alias is shared between trait and implementation
pub(crate) type CausalGraph<T> = UltraGraphWeighted<T, u64>;
