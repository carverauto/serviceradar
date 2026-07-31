/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::ConstTree;

impl<T: Default> Default for ConstTree<T> {
    fn default() -> Self {
        Self::new(T::default())
    }
}
