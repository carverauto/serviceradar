/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::DynamicGraph;

pub trait Unfreezable<N, W> {
    fn unfreeze(self) -> DynamicGraph<N, W>;
}
