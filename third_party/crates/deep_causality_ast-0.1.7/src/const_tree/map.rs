/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::ConstTree;
use std::sync::Arc;

impl<T: Clone> ConstTree<ConstTree<T>> {
    /// Flattens a tree of trees into a single tree.
    ///
    /// This is the `join` operation of a Monad. It takes a `ConstTree` where each node's
    /// value is another `ConstTree`, and collapses it into a single `ConstTree`.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_ast::ConstTree;
    /// // Create a tree of trees: ConstTree<ConstTree<i32>>
    /// let inner_tree = ConstTree::with_children(1, vec![ConstTree::new(2)]);
    /// let tree_of_trees = ConstTree::new(inner_tree);
    ///
    /// let joined = tree_of_trees.join();
    ///
    /// assert_eq!(*joined.value(), 1);
    /// assert_eq!(joined.children().len(), 1);
    /// assert_eq!(*joined.children()[0].value(), 2);
    /// ```
    pub fn join(self) -> ConstTree<T> {
        // Consume the outer node when possible to avoid unnecessary clones.
        let outer_node = Arc::try_unwrap(self.node).unwrap_or_else(|arc| (*arc).clone());

        // Take the inner tree (value of the outer root).
        let inner_tree = outer_node.value;

        // Start with inner_tree's existing children.
        let mut new_children = inner_tree.children().to_vec();

        // Recursively join each outer child into a flat ConstTree<T>.
        new_children.extend(outer_node.children.into_iter().map(|c| c.join()));

        // Build the resulting tree using the inner root value.
        ConstTree::with_children(inner_tree.value().clone(), new_children)
    }
}

impl<T: Clone> ConstTree<T> {
    /// Consumes the tree and creates a new tree by applying a function to each value.
    ///
    /// This is the consuming equivalent of `map()`, analogous to `into_iter()`.
    /// Because this method consumes the tree, it can yield owned values `T` to the closure.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_ast::ConstTree;
    /// let tree = ConstTree::with_children(1, vec![ConstTree::new(2)]);
    /// // The original tree is moved here.
    /// let mapped_tree = tree.into_map(|v| v.to_string());
    ///
    /// assert_eq!(*mapped_tree.value(), "1");
    /// assert_eq!(*mapped_tree.children()[0].value(), "2");
    /// ```
    pub fn into_map<F, U>(self, mut f: F) -> ConstTree<U>
    where
        F: FnMut(T) -> U,
        U: Clone,
    {
        // A recursive helper function to handle the consumption.
        fn recursive_into_map<T, U, F>(tree: ConstTree<T>, f: &mut F) -> ConstTree<U>
        where
            T: Clone,
            F: FnMut(T) -> U,
            U: Clone,
        {
            // Try to unwrap the Arc to take ownership of the Node.
            // If it fails, it means the node is shared, so we must clone its contents.
            let node = Arc::try_unwrap(tree.node).unwrap_or_else(|arc| (*arc).clone());

            let new_value = f(node.value);
            let new_children: Vec<_> = node
                .children
                .into_iter()
                .map(|c| recursive_into_map(c, f))
                .collect();
            ConstTree::with_children(new_value, new_children)
        }

        recursive_into_map(self, &mut f)
    }
}

impl<T> ConstTree<T> {
    /// Creates a new tree by applying a function to a reference of each value.
    ///
    /// This is a non-destructive operation that returns a new `ConstTree`.
    /// The closure receives a reference `&T`.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_ast::ConstTree;
    /// let tree = ConstTree::with_children(1, vec![ConstTree::new(2)]);
    /// let mapped_tree = tree.map(&mut |v| v * 2);
    ///
    /// assert_eq!(*tree.value(), 1); // Original is unchanged
    /// assert_eq!(*mapped_tree.value(), 2);
    /// assert_eq!(*mapped_tree.children()[0].value(), 4);
    /// ```
    pub fn map<F, U>(&self, f: &mut F) -> ConstTree<U>
    where
        F: FnMut(&T) -> U,
        U: Clone, // The new value type must be cloneable
    {
        let new_value = f(self.value());
        let new_children: Vec<_> = self.children().iter().map(|child| child.map(f)).collect();
        ConstTree::with_children(new_value, new_children)
    }
}
