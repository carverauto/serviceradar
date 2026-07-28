/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::ConstTree;
use std::collections::VecDeque;

impl<T> ConstTree<T> {
    /// Returns an iterator that traverses the tree's values in pre-order (root, then children).
    ///
    /// # Examples
    /// ```
    /// use deep_causality_ast::ConstTree;
    /// let tree = ConstTree::with_children(1, vec![ConstTree::new(2), ConstTree::new(3)]);
    /// let values: Vec<_> = tree.iter_pre_order().copied().collect();
    /// assert_eq!(values, vec![1, 2, 3]);
    /// ```
    pub fn iter_pre_order(&self) -> PreOrderIter<'_, T> {
        PreOrderIter { stack: vec![self] }
    }

    /// Returns an iterator that traverses the tree's nodes (`ConstTree` handles) in pre-order.
    ///
    /// This is useful for finding nodes or performing operations on the tree structure itself.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_ast::ConstTree;
    /// let tree = ConstTree::with_children(1, vec![ConstTree::new(2)]);
    /// let nodes: Vec<_> = tree.iter_nodes_pre_order().collect();
    /// assert!(nodes[0].ptr_eq(&tree));
    /// assert_eq!(*nodes[1].value(), 2);
    /// ```
    pub fn iter_nodes_pre_order(&self) -> PreOrderNodeIter<'_, T> {
        PreOrderNodeIter { stack: vec![self] }
    }

    /// Returns an iterator that traverses the tree's values in post-order (children, then root).
    ///
    /// # Examples
    /// ```
    /// use deep_causality_ast::ConstTree;
    /// let tree = ConstTree::with_children(1, vec![ConstTree::new(2), ConstTree::new(3)]);
    /// let values: Vec<_> = tree.iter_post_order().copied().collect();
    /// assert_eq!(values, vec![2, 3, 1]);
    /// ```
    pub fn iter_post_order(&self) -> PostOrderIter<'_, T> {
        PostOrderIter::new(self)
    }

    /// Returns an iterator that traverses the tree's values in level-order (breadth-first).
    ///
    /// # Examples
    /// ```
    /// use deep_causality_ast::ConstTree;
    /// let tree = ConstTree::with_children(1, vec![ConstTree::with_children(2, vec![ConstTree::new(4)]), ConstTree::new(3)]);
    /// let values: Vec<_> = tree.iter_level_order().copied().collect();
    /// assert_eq!(values, vec![1, 2, 3, 4]);
    /// ```
    pub fn iter_level_order(&self) -> LevelOrderIter<'_, T> {
        let mut queue = VecDeque::new();
        queue.push_back(self);
        LevelOrderIter { queue }
    }
}

/// An iterator that traverses a `ConstTree` in pre-order (root, then children).
pub struct PreOrderIter<'a, T> {
    stack: Vec<&'a ConstTree<T>>,
}

impl<'a, T> Iterator for PreOrderIter<'a, T> {
    type Item = &'a T;
    fn next(&mut self) -> Option<Self::Item> {
        let tree = self.stack.pop()?;
        self.stack.extend(tree.children().iter().rev());
        Some(tree.value())
    }
}

/// An iterator that traverses a `ConstTree`'s nodes in pre-order.
pub struct PreOrderNodeIter<'a, T> {
    stack: Vec<&'a ConstTree<T>>,
}

impl<'a, T> Iterator for PreOrderNodeIter<'a, T> {
    type Item = &'a ConstTree<T>;
    fn next(&mut self) -> Option<Self::Item> {
        let tree = self.stack.pop()?;
        self.stack.extend(tree.children().iter().rev());
        Some(tree)
    }
}

/// An iterator that traverses a `ConstTree` in post-order (children, then root).
/// It maintains a stack containing tuples of a node and an iterator over its children.
pub struct PostOrderIter<'a, T> {
    stack: Vec<(&'a ConstTree<T>, std::slice::Iter<'a, ConstTree<T>>)>,
}

impl<'a, T> PostOrderIter<'a, T> {
    /// Creates a new post-order iterator starting at the given root.
    pub fn new(root: &'a ConstTree<T>) -> Self {
        let mut iter = PostOrderIter { stack: Vec::new() };
        let children_iter = root.children().iter();
        iter.stack.push((root, children_iter));
        iter
    }
}

impl<'a, T> Iterator for PostOrderIter<'a, T> {
    type Item = &'a T;

    fn next(&mut self) -> Option<Self::Item> {
        // Loop until we find the next node to yield or the stack is empty.
        loop {
            // Peek at the top of the stack to see which node we're processing.
            let (_current_node, children_iter) = self.stack.last_mut()?;

            // Try to get the next child of the current node.
            match children_iter.next() {
                Some(child_node) => {
                    // If there is a child, create its own entry and push it onto the stack.
                    let grand_children_iter = child_node.children().iter();
                    self.stack.push((child_node, grand_children_iter));
                }
                None => {
                    // If there are no more children, it means we have visited all descendants
                    // of `current_node`. It is now time to visit `current_node` itself.
                    // We pop it from the stack and return its value.
                    let (finished_node, _) = self.stack.pop().unwrap();
                    return Some(finished_node.value());
                }
            }
        }
    }
}

/// An iterator that traverses a `ConstTree` in level-order (breadth-first).
pub struct LevelOrderIter<'a, T> {
    queue: VecDeque<&'a ConstTree<T>>,
}

impl<'a, T> Iterator for LevelOrderIter<'a, T> {
    type Item = &'a T;
    fn next(&mut self) -> Option<Self::Item> {
        let tree = self.queue.pop_front()?;
        self.queue.extend(tree.children().iter());
        Some(tree.value())
    }
}
