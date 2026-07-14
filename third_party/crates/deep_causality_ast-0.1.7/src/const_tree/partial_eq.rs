/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::ConstTree;
use std::sync::Arc;

// Allow comparing trees for equality if their values can be compared.
impl<T: PartialEq> PartialEq for ConstTree<T> {
    fn eq(&self, other: &Self) -> bool {
        if Arc::ptr_eq(&self.node, &other.node) {
            return true;
        }
        self.node.value == other.node.value && self.node.children == other.node.children
    }
}

impl<T: Eq> Eq for ConstTree<T> {}
