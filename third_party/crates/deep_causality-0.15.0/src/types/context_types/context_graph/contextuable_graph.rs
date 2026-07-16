/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use ultragraph::*;

use crate::{
    Context, ContextIndexError, Contextoid, ContextoidId, ContextuableGraph, Datable, Identifiable,
    RelationKind, SpaceTemporal, Spatial, Symbolic, Temporal,
};

#[allow(clippy::type_complexity)]
impl<D, S, T, ST, SYM, VS, VT> ContextuableGraph<D, S, T, ST, SYM, VS, VT>
    for Context<D, S, T, ST, SYM, VS, VT>
where
    D: Datable + Clone,
    S: Spatial<VS> + Clone,
    T: Temporal<VT> + Clone,
    ST: SpaceTemporal<VS, VT> + Clone,
    SYM: Symbolic + Clone,
    VS: Clone,
    VT: Clone,
{
    fn add_node(
        &mut self,
        value: Contextoid<D, S, T, ST, SYM, VS, VT>,
    ) -> Result<usize, ContextIndexError> {
        let contextoid_id = value.id();
        let index = match self.base_context.add_node(value) {
            Ok(index) => index,
            Err(e) => return Err(ContextIndexError(e.to_string())),
        };
        self.id_to_index_map.insert(contextoid_id, index);
        Ok(index)
    }

    /// Returns only true if the context contains the contextoid with the given index.
    fn contains_node(&self, index: usize) -> bool {
        self.base_context.contains_node(index)
    }

    /// Returns a reference to the contextoid with the given index.
    /// If the context does not contain the contextoid, it will return None.
    fn get_node(&self, index: usize) -> Option<&Contextoid<D, S, T, ST, SYM, VS, VT>> {
        self.base_context.get_node(index)
    }

    fn remove_node(&mut self, node_id: ContextoidId) -> Result<(), ContextIndexError> {
        if let Some(&index_to_remove) = self.id_to_index_map.get(&node_id) {
            // Try to remove from the underlying graph first.
            self.base_context
                .remove_node(index_to_remove)
                .map_err(|e| ContextIndexError(e.to_string()))?;

            // If successful, then remove the entry from our map to stay in sync.
            self.id_to_index_map.remove(&node_id);

            Ok(())
        } else {
            Err(ContextIndexError(format!(
                "Cannot remove node. Contextoid with ID {node_id} not found in context"
            )))
        }
    }

    fn update_node(
        &mut self,
        node_id: ContextoidId,
        new_node: Contextoid<D, S, T, ST, SYM, VS, VT>,
    ) -> Result<(), ContextIndexError> {
        if let Some(&index_to_update) = self.id_to_index_map.get(&node_id) {
            let new_node_id = new_node.id(); // Extract the new node's ID

            self.base_context
                .update_node(index_to_update, new_node)
                .map_err(|e| ContextIndexError(e.to_string()))?;

            // Update id_to_index_map if the ID changed to maintain consistency
            if new_node_id != node_id {
                self.id_to_index_map.remove(&node_id);
                self.id_to_index_map.insert(new_node_id, index_to_update);
            }

            Ok(())
        } else {
            Err(ContextIndexError(format!(
                "Cannot update node. Contextoid with ID {node_id} not found in context"
            )))
        }
    }

    /// Adds a new weighted edge between two nodes.
    /// Returns either Ok after success, or ContextIndexError if
    /// any of the nodes are not in the context.
    fn add_edge(
        &mut self,
        a: usize,
        b: usize,
        weight: RelationKind,
    ) -> Result<(), ContextIndexError> {
        if !self.contains_node(a) {
            return Err(ContextIndexError(format!("index a {a} not found")));
        };

        if !self.contains_node(b) {
            return Err(ContextIndexError(format!("index b {b} not found")));
        };

        if self.base_context.add_edge(a, b, weight as u64).is_err() {
            return Err(ContextIndexError(format!(
                "Failed to add edge for index a {a} and b {b}"
            )));
        }

        Ok(())
    }

    /// Returns only true if the context contains the edge between the two nodes.
    /// If the context does not contain the edge or any of the nodes it will return false.
    /// You may want to call contains_node first to ascertain that the nodes are in the context.
    fn contains_edge(&self, a: usize, b: usize) -> bool {
        self.base_context.contains_edge(a, b)
    }

    /// Removes an edge between two nodes.
    /// Returns either Ok after success, or ContextIndexError if
    /// any of the nodes are not in the context.
    fn remove_edge(&mut self, a: usize, b: usize) -> Result<(), ContextIndexError> {
        if !self.contains_node(a) {
            return Err(ContextIndexError("index a not found".into()));
        };

        if !self.contains_node(b) {
            return Err(ContextIndexError("index b not found".into()));
        };
        self.base_context
            .remove_edge(a, b)
            .map_err(|e| ContextIndexError(e.to_string()))
    }

    /// Returns the number of nodes in the context. Alias for node_count().
    fn size(&self) -> usize {
        self.base_context.number_nodes()
    }

    /// Returns true if the context contains no nodes.
    fn is_empty(&self) -> bool {
        self.base_context.is_empty()
    }

    /// Returns the number of nodes in the context.
    fn number_of_nodes(&self) -> usize {
        self.base_context.number_nodes()
    }

    /// Returns the number of edges in the context.
    fn number_of_edges(&self) -> usize {
        self.base_context.number_edges()
    }
}
