/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use std::sync::Arc;

mod accessors;
mod api;
mod clone;
mod debug;
mod default;
mod display;
mod from;
mod into_iter;
mod iter;
mod map;
mod partial_eq;

// The internal, private representation of a single node in the tree.
// Deriving Debug is useful for internal debugging.
#[derive(Debug)]
struct Node<T> {
    value: T,
    children: Vec<ConstTree<T>>, // Children are also trees. This makes the structure recursive.
}

impl<T: Clone> Clone for Node<T> {
    fn clone(&self) -> Self {
        Node {
            value: self.value.clone(),
            children: self.children.clone(),
        }
    }
}

/// A persistent, immutable tree structure.
///
/// `ConstTree` is a handle to a tree node. Cloning a `ConstTree` is a cheap,
/// constant-time operation as it only increments a reference count.
///
/// All modification methods (`with_value`, `add_child`, etc.) are non-destructive.
/// They return a new `ConstTree` representing the modified version, leaving the
/// original unchanged and sharing as much memory as possible.
pub struct ConstTree<T> {
    // The public API wraps an Arc around the private Node.
    // This is the core of the persistent data structure pattern.
    node: Arc<Node<T>>,
}

// Constructors
impl<T> ConstTree<T> {
    /// Creates a new `ConstTree` with a single root node and no children (a leaf).
    ///
    /// # Example
    /// ```
    /// use deep_causality_ast::ConstTree;
    /// let leaf = ConstTree::new(10);
    /// assert_eq!(*leaf.value(), 10);
    /// assert!(leaf.is_leaf());
    /// ```
    pub fn new(value: T) -> Self {
        Self {
            node: Arc::new(Node {
                value,
                children: Vec::new(),
            }),
        }
    }

    /// Creates a new `ConstTree` with a root node and a given set of children.
    ///
    /// The `children` argument can be any type that can be converted into an iterator
    /// over `ConstTree<T>`, such as a `Vec<ConstTree<T>>` or a slice `&[ConstTree<T>]`.
    ///
    /// # Example
    /// ```
    /// use deep_causality_ast::ConstTree;
    /// let leaf1 = ConstTree::new(1);
    /// let leaf2 = ConstTree::new(2);
    /// let tree = ConstTree::with_children(0, vec![leaf1, leaf2]);
    /// assert_eq!(tree.children().len(), 2);
    /// ```
    pub fn with_children(value: T, children: impl IntoIterator<Item = Self>) -> Self {
        Self {
            node: Arc::new(Node {
                value,
                children: children.into_iter().collect(),
            }),
        }
    }

    /// Returns a new `ConstTree` with the root value replaced.
    ///
    /// This is a non-destructive, O(1) operation. The children of the new tree are
    /// shared with the original tree, avoiding a deep copy.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_ast::ConstTree;
    /// let original = ConstTree::with_children(1, vec![ConstTree::new(2)]);
    /// let with_new_value = original.with_value(99);
    ///
    /// assert_eq!(*original.value(), 1);
    /// assert_eq!(*with_new_value.value(), 99);
    /// // The children are shared between the two trees.
    /// assert!(original.children()[0].ptr_eq(&with_new_value.children()[0]));
    /// ```
    pub fn with_value<V: Into<T>>(&self, new_value: V) -> Self {
        Self {
            node: Arc::new(Node {
                value: new_value.into(),
                children: self.node.children.clone(),
            }),
        }
    }
}
