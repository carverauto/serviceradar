/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::ConstTree;

/// An iterator that consumes a `ConstTree` and yields its values.
/// Traverses the tree in pre-order.
pub struct IntoIter<T: Clone> {
    stack: Vec<ConstTree<T>>,
}

impl<T: Clone> Iterator for IntoIter<T> {
    type Item = T;

    fn next(&mut self) -> Option<Self::Item> {
        let tree = self.stack.pop()?;

        match std::sync::Arc::try_unwrap(tree.node) {
            Ok(node) => {
                self.stack.extend(node.children.into_iter().rev());
                Some(node.value)
            }
            Err(arc) => {
                self.stack.extend(arc.children.iter().rev().cloned());
                Some(arc.value.clone())
            }
        }
    }
}

impl<T: Clone> IntoIterator for ConstTree<T> {
    type Item = T;
    type IntoIter = IntoIter<T>;

    fn into_iter(self) -> Self::IntoIter {
        IntoIter { stack: vec![self] }
    }
}
