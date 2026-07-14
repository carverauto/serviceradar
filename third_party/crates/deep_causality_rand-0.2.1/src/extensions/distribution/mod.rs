/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Type-specific distribution extensions: the `StandardUniform` / `Open01` /
//! `OpenClosed01` (and `Float106` `StandardNormal`) impls for the concrete float
//! types, segregated from the core distribution machinery in `types::distr`.

mod dist_float_common;

pub mod dist_float_106;
pub mod dist_float_32;
pub mod dist_float_64;
