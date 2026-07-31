/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::ConstTree;
use crate::const_tree::Node;
use std::sync::Arc;

impl<T: Clone> ConstTree<T> {
    /// Returns a new `ConstTree` with an additional child appended to the end of the
    /// children list.
    ///
    /// This is a non-destructive operation. The original `ConstTree` is not modified.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_ast::ConstTree;
    /// let original = ConstTree::new(1);
    /// let with_child = original.add_child(ConstTree::new(2));
    ///
    /// assert!(original.is_leaf());
    /// assert_eq!(with_child.children().len(), 1);
    /// ```
    pub fn add_child(&self, child: ConstTree<T>) -> Self {
        let mut new_children = self.node.children.clone();
        new_children.push(child);

        Self {
            node: Arc::new(Node {
                value: self.node.value.clone(),
                children: new_children,
            }),
        }
    }

    /// Returns a new `ConstTree` with the children replaced by a new set.
    ///
    /// This is a non-destructive operation. The original `ConstTree` is not modified.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_ast::ConstTree;
    /// let original = ConstTree::with_children(1, vec![ConstTree::new(2)]);
    /// let replaced = original.replace_children(vec![ConstTree::new(3), ConstTree::new(4)]);
    ///
    /// assert_eq!(original.children().len(), 1);
    /// assert_eq!(replaced.children().len(), 2);
    /// assert_eq!(*replaced.children()[0].value(), 3);
    /// ```
    pub fn replace_children(&self, new_children: impl IntoIterator<Item = Self>) -> Self {
        Self {
            node: Arc::new(Node {
                value: self.node.value.clone(),
                children: new_children.into_iter().collect(),
            }),
        }
    }

    /// Returns a new `ConstTree` with the child at the specified `index` updated.
    ///
    /// This is a non-destructive operation. The original `ConstTree` is not modified.
    ///
    /// # Returns
    /// An `Option` containing the new `ConstTree`, or `None` if the index is out of bounds.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_ast::ConstTree;
    /// let original = ConstTree::with_children(1, vec![ConstTree::new(2)]);
    /// let updated = original.update_child(0, ConstTree::new(99)).unwrap();
    ///
    /// assert_eq!(*original.children()[0].value(), 2);
    /// assert_eq!(*updated.children()[0].value(), 99);
    /// assert!(original.update_child(1, ConstTree::new(100)).is_none());
    /// ```
    pub fn update_child(&self, index: usize, new_child: ConstTree<T>) -> Option<Self> {
        if index >= self.node.children.len() {
            return None;
        }
        let mut new_children = self.node.children.clone();
        new_children[index] = new_child;
        Some(Self {
            node: Arc::new(Node {
                value: self.node.value.clone(),
                children: new_children,
            }),
        })
    }

    /// Returns a new `ConstTree` with the child at the specified `index` removed.
    ///
    /// This is a non-destructive operation. The original `ConstTree` is not modified.
    ///
    /// # Returns
    /// An `Option` containing the new `ConstTree`, or `None` if the index is out of bounds.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_ast::ConstTree;
    /// let original = ConstTree::with_children(1, vec![ConstTree::new(2)]);
    /// let removed = original.remove_child(0).unwrap();
    ///
    /// assert_eq!(original.children().len(), 1);
    /// assert!(removed.is_leaf());
    /// assert!(original.remove_child(1).is_none());
    /// ```
    pub fn remove_child(&self, index: usize) -> Option<Self> {
        if index >= self.node.children.len() {
            return None;
        }
        let mut new_children = self.node.children.clone();
        new_children.remove(index);
        Some(Self {
            node: Arc::new(Node {
                value: self.node.value.clone(),
                children: new_children,
            }),
        })
    }
}

impl<T: PartialEq> ConstTree<T> {
    /// Checks if the tree contains a given value by traversing in pre-order.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_ast::ConstTree;
    /// let tree = ConstTree::with_children(1, vec![ConstTree::new(2), ConstTree::new(3)]);
    /// assert!(tree.contains(&2));
    /// assert!(!tree.contains(&4));
    /// ```
    pub fn contains(&self, value: &T) -> bool {
        self.iter_pre_order().any(|v| v == value)
    }
}
