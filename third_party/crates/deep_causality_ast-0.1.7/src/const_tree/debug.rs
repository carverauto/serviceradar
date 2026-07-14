/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::ConstTree;
use std::fmt;

impl<T: fmt::Debug> fmt::Debug for ConstTree<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ConstTree")
            .field("value", &self.node.value)
            .field("children_count", &self.node.children.len())
            .finish()
    }
}
