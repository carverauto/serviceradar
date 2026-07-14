/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::ConstTree;
use std::collections::VecDeque;
use std::sync::Arc;

impl<T> ConstTree<T> {
    /// Returns a reference to the value stored at the root of the tree.
    pub fn value(&self) -> &T {
        &self.node.value
    }

    /// Returns a slice containing the children of the root node.
    pub fn children(&self) -> &[ConstTree<T>] {
        &self.node.children
    }

    /// Checks if two `ConstTree` handles point to the same underlying `Arc` allocation.
    ///
    /// This is the most efficient way to check for equality, but it only returns `true`
    /// if the two handles were created from the same original tree or via `clone()`.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_ast::ConstTree;
    /// let tree1 = ConstTree::new(1);
    /// let tree2 = ConstTree::new(1); // Same value, different allocation
    /// let tree1_clone = tree1.clone();
    ///
    /// assert!(tree1.ptr_eq(&tree1_clone));
    /// assert!(!tree1.ptr_eq(&tree2));
    /// ```
    pub fn ptr_eq(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.node, &other.node)
    }

    /// Returns a specific child by its index.
    ///
    /// # Returns
    /// An `Option` containing a reference to the child `ConstTree`, or `None` if the
    /// index is out of bounds.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_ast::ConstTree;
    /// let tree = ConstTree::with_children(0, vec![ConstTree::new(1), ConstTree::new(2)]);
    /// assert_eq!(*tree.get_child(0).unwrap().value(), 1);
    /// assert!(tree.get_child(2).is_none());
    /// ```
    pub fn get_child(&self, index: usize) -> Option<&ConstTree<T>> {
        self.node.children.get(index)
    }

    /// Returns a unique identifier for the node pointed to by this `ConstTree`.
    ///
    /// The ID is the memory address of the underlying `Arc`'s allocation.
    pub fn get_id(&self) -> usize {
        Arc::as_ptr(&self.node) as usize
    }

    /// Checks if the tree is a leaf node (i.e., has no children).
    pub fn is_leaf(&self) -> bool {
        self.node.children.is_empty()
    }

    /// Returns the total number of nodes in the tree (including the root).
    ///
    /// # Complexity
    /// This is an O(n) operation as it traverses the entire tree.
    pub fn size(&self) -> usize {
        self.iter_pre_order().count()
    }

    /// Returns the maximum depth of the tree.
    ///
    /// A leaf node has a depth of 1.
    ///
    /// # Complexity
    /// This is an O(n) iterative operation that is robust against stack overflows for
    /// very deep trees.
    pub fn depth(&self) -> usize {
        let mut max_depth = 0;
        let mut queue = VecDeque::new();

        // Start with the root node at depth 1.
        queue.push_back((self, 1));

        while let Some((current_node, current_depth)) = queue.pop_front() {
            max_depth = max_depth.max(current_depth);
            for child in current_node.children() {
                queue.push_back((child, current_depth + 1));
            }
        }
        max_depth
    }

    /// Finds the first node that satisfies a predicate in pre-order traversal.
    ///
    /// # Arguments
    /// * `predicate`: A closure that takes a reference to a value and returns `true`
    ///   for the node being sought.
    ///
    /// # Returns
    /// An `Option` containing a reference to the found `ConstTree`, or `None`.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_ast::ConstTree;
    /// let tree = ConstTree::with_children(10, vec![ConstTree::from(20), ConstTree::from(30)]);
    /// let found_node = tree.find(|v| *v > 25).unwrap();
    /// assert_eq!(*found_node.value(), 30);
    /// ```
    pub fn find<P>(&self, predicate: P) -> Option<&ConstTree<T>>
    where
        P: Fn(&T) -> bool,
    {
        self.iter_nodes_pre_order()
            .find(|node| predicate(node.value()))
    }

    /// Returns an iterator over all nodes that satisfy a predicate in pre-order traversal.
    ///
    /// # Arguments
    /// * `predicate`: A closure that takes a reference to a value and returns `true`
    ///   for the nodes to be included in the iterator.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_ast::ConstTree;
    /// let tree = ConstTree::with_children(10, vec![ConstTree::new(20), ConstTree::new(30)]);
    /// let results: Vec<_> = tree.find_all(|v| *v > 15).map(|n| *n.value()).collect();
    /// assert_eq!(results, vec![20, 30]);
    /// ```
    pub fn find_all<P>(&self, predicate: P) -> impl Iterator<Item = &ConstTree<T>>
    where
        P: Fn(&T) -> bool,
    {
        self.iter_nodes_pre_order()
            .filter(move |node| predicate(node.value()))
    }
}
