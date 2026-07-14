/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{DynamicGraph, GraphError, GraphMut, GraphView};

impl<N, W> GraphMut<N, W> for DynamicGraph<N, W> {
    /// Adds a new node with the given node to the graph.
    ///
    /// This operation is amortized O(1). It adds a new entry for the node
    /// and its corresponding edge list. It returns the stable `usize` index
    /// that will identify this node for its lifetime.
    fn add_node(&mut self, node: N) -> Result<usize, GraphError> {
        let index = self.nodes.len();
        self.nodes.push(Some(node));

        if let Some(edge_capacity) = self.num_edges_per_node {
            self.edges.push(Vec::with_capacity(edge_capacity)); // Add a corresponding edge list with edge_capacity
        } else {
            self.edges.push(Vec::default()); // Add a corresponding empty edge list
        };

        Ok(index)
    }

    /// Updates the node of an existing, non-tombstoned node.
    ///
    /// # Errors
    /// Returns `GraphError::NodeNotFound` if the index is out of bounds or if the
    /// node at that index has already been removed.
    fn update_node(&mut self, index: usize, node: N) -> Result<(), GraphError> {
        // `get_mut` performs the bounds check.
        match self.nodes.get_mut(index) {
            // Check if the node is not a tombstone.
            Some(node_slot) if node_slot.is_some() => {
                *node_slot = Some(node); // Update the node
                Ok(())
            }
            // Either out of bounds or a tombstone, it's considered not found.
            _ => Err(GraphError::NodeNotFound(index)),
        }
    }

    /// Removes a node from the graph, effectively "tombstoning" it.
    ///
    /// This operation marks the node as removed by setting its `Option<N>` to `None`,
    /// preserving the stability of existing node indices. Edges connected to
    /// this node are logically removed but remain in the adjacency lists until
    /// the graph is `freeze`n.
    ///
    /// # Errors
    /// Returns `GraphError::NodeNotFound` if the index is out of bounds or if the
    /// node at that index has already been removed.
    fn remove_node(&mut self, index: usize) -> Result<(), GraphError> {
        // `get_mut` performs the bounds check.
        match self.nodes.get_mut(index) {
            // Check if the node is not already a tombstone.
            Some(node_slot) if node_slot.is_some() => {
                *node_slot = None; // "Tombstone" the node
                // Clear its outgoing edges. Incoming edges will be handled during freeze.
                if let Some(edges_list) = self.edges.get_mut(index) {
                    edges_list.clear();
                }
                // If this was the root, clear the root index
                if self.root_index == Some(index) {
                    self.root_index = None;
                }
                Ok(())
            }
            // Either out of bounds or already a tombstone.
            _ => Err(GraphError::NodeNotFound(index)),
        }
    }

    /// Adds a directed edge between two nodes with a given weight.
    ///
    /// # Errors
    /// Returns `GraphError::EdgeCreationError` if either the source or target node
    /// does not exist (or has been removed). This implementation allows for parallel edges.
    fn add_edge(&mut self, a: usize, b: usize, weight: W) -> Result<(), GraphError> {
        // Use the `GraphView` trait's own method to ensure nodes are valid.
        if !self.contains_node(a) || !self.contains_node(b) {
            return Err(GraphError::EdgeCreationError {
                source: a,
                target: b,
            });
        }

        // This check is safe because `contains_node` confirmed `a` is in bounds.
        self.edges[a].push((b, weight));
        Ok(())
    }

    /// Removes a directed edge between two nodes.
    ///
    /// If multiple parallel edges exist, this removes the first one found.
    /// This operation is O(degree(a)).
    ///
    /// # Errors
    /// Returns `GraphError::NodeNotFound` if the source node does not exist.
    /// Returns `GraphError::EdgeNotFoundError` if the specified edge does not exist.
    fn remove_edge(&mut self, a: usize, b: usize) -> Result<(), GraphError> {
        // Check if the source node is valid first.
        if !self.contains_node(a) {
            return Err(GraphError::NodeNotFound(a));
        }

        // Find the position of the edge in the source node's adjacency list.
        if let Some(pos) = self.edges[a].iter().position(|(target, _)| *target == b) {
            // Use `swap_remove` for O(1) removal (amortized), as edge order is not guaranteed.
            self.edges[a].swap_remove(pos);
            Ok(())
        } else {
            Err(GraphError::EdgeNotFoundError {
                source: a,
                target: b,
            })
        }
    }

    /// Adds a new node and designates it as the graph's root node.
    /// Any previous root designation is overwritten.
    fn add_root_node(&mut self, node: N) -> Result<usize, GraphError> {
        if self.root_index.is_none() {
            let index = self.add_node(node)?;
            self.root_index = Some(index);
            Ok(index)
        } else {
            Err(GraphError::RootNodeAlreadyExists)
        }
    }

    /// Clears all nodes and edges from the graph, resetting it to an empty state.
    fn clear(&mut self) -> Result<(), GraphError> {
        self.nodes.clear();
        self.edges.clear();
        self.root_index = None;
        Ok(())
    }
}
