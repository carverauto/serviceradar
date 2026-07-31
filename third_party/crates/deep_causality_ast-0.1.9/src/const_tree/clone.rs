/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::ConstTree;

// Clone is cheap because it just clones the Arc.
impl<T> Clone for ConstTree<T> {
    fn clone(&self) -> Self {
        Self {
            node: self.node.clone(),
        }
    }
}
