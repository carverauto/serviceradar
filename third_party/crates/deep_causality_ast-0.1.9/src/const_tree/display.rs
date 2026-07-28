/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::ConstTree;
use std::fmt;

impl<T: fmt::Display> fmt::Display for ConstTree<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.fmt_recursive(f, 0)
    }
}

impl<T> ConstTree<T> {
    // Private helper for Display trait to recursively print the tree with indentation.
    pub(super) fn fmt_recursive(&self, f: &mut fmt::Formatter<'_>, indent: usize) -> fmt::Result
    where
        T: fmt::Display,
    {
        writeln!(f, "{:indent$}{}", "", self.node.value, indent = indent * 4)?; // 4 spaces per indent level
        for child in &self.node.children {
            child.fmt_recursive(f, indent + 1)?;
        }
        Ok(())
    }
}
