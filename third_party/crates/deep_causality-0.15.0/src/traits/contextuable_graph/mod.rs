/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::errors::ContextIndexError;
use crate::traits::contextuable::space_temporal::SpaceTemporal;
use crate::traits::contextuable::spatial::Spatial;
use crate::traits::contextuable::temporal::Temporal;
use crate::{Contextoid, ContextoidId, Datable, RelationKind, Symbolic};

/// Trait for graph containing context-aware nodes.
///
/// D: Datable trait object
/// S: Spatial trait object
/// T: Temporable trait object
/// ST: SpaceTemporal trait object
/// V: Numeric type for dimension values
///
/// Provides methods for:
/// - Adding/removing nodes and edges
/// - Checking if nodes/edges exist
/// - Getting node references
/// - Getting graph size and counts
///
/// Nodes are Contextoid objects implementing required traits.
/// Edges have a relation kind weight.
///
/// Methods return Result or Option types for error handling.
///
#[allow(clippy::type_complexity)]
pub trait ContextuableGraph<D, S, T, ST, SYM, VS, VT>
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
    ) -> Result<usize, ContextIndexError>;
    fn contains_node(&self, index: usize) -> bool;
    fn get_node(&self, index: usize) -> Option<&Contextoid<D, S, T, ST, SYM, VS, VT>>;
    fn remove_node(&mut self, node_id: ContextoidId) -> Result<(), ContextIndexError>;
    fn update_node(
        &mut self,
        node_id: ContextoidId,
        new_node: Contextoid<D, S, T, ST, SYM, VS, VT>,
    ) -> Result<(), ContextIndexError>;
    fn add_edge(
        &mut self,
        a: usize,
        b: usize,
        weight: RelationKind,
    ) -> Result<(), ContextIndexError>;
    fn contains_edge(&self, a: usize, b: usize) -> bool;
    fn remove_edge(&mut self, a: usize, b: usize) -> Result<(), ContextIndexError>;
    fn size(&self) -> usize;
    fn is_empty(&self) -> bool;
    // Corrected method names
    fn number_of_nodes(&self) -> usize;
    fn number_of_edges(&self) -> usize;
}

/// Trait for poly-contextuable causal graphs.
/// By default, the context graph is assumed to be a single-context graph.
///
/// This trait supports multiple contexts by extending the ContextuableGraph trait.
///
/// Extends ContextuableGraph trait with methods for:
///
/// - Creating and managing additional "contexts"
/// - Setting a current context ID
/// - Context-specific node/edge methods
///
/// Provides methods for:
///
/// - Creating new contexts
/// - Checking if a context ID exists
/// - Getting/setting current context ID
/// - Context-specific node and edge methods
///
/// Nodes are Contextoid objects implementing required traits.
/// Edges have a relation kind weight.
///
/// Methods return Result or Option types for error handling.
///
#[allow(clippy::type_complexity)]
pub trait ExtendableContextuableGraph<D, S, T, ST, SYM, VS, VT>
where
    D: Datable + Clone,
    S: Spatial<VS> + Clone,
    T: Temporal<VT> + Clone,
    ST: SpaceTemporal<VS, VT> + Clone,
    SYM: Symbolic + Clone,
    VS: Clone,
    VT: Clone,
{
    /// Creates a new, empty "extra" context and adds it to the collection.
    ///
    /// This method generates a unique ID for the new context internally.
    ///
    /// # Parameters
    /// - `capacity`: The initial storage capacity to pre-allocate for the new context's graph.
    /// - `default`: If `true`, the newly created context is immediately set as the
    ///   currently active context for subsequent `extra_ctx_*` operations.
    ///
    /// # Returns
    /// The unique `u64` ID assigned to the newly created context.
    fn extra_ctx_add_new(&mut self, capacity: usize, default: bool) -> u64;

    /// Creates a new extra context with a specific, user-provided ID.
    ///
    /// This is useful for scenarios where context IDs need to be deterministic,
    /// such as when reconstructing a state from a saved configuration.
    ///
    /// # Parameters
    /// - `id`: The user-defined `u64` ID for the new context.
    /// - `capacity`: The initial storage capacity for the new context's graph.
    /// - `default`: If `true`, this new context is set as the currently active one.
    ///
    /// # Returns
    /// - `Ok(())` if the context was created successfully.
    ///
    /// # Errors
    /// - `ContextIndexError` if a context with the provided `id` already exists.
    fn extra_ctx_add_new_with_id(
        &mut self,
        id: u64,
        capacity: usize,
        default: bool,
    ) -> Result<(), ContextIndexError>;

    /// Checks if an extra context with the given ID exists.
    ///
    /// # Parameters
    /// - `idx`: The `u64` ID of the context to check for.
    ///
    /// # Returns
    /// `true` if a context with the specified ID exists, `false` otherwise.
    fn extra_ctx_check_exists(&self, idx: u64) -> bool;

    /// Gets the ID of the currently active extra context.
    ///
    /// By convention, an ID of `0` indicates that no extra context is currently active,
    /// and operations will target the primary context.
    ///
    /// # Returns
    /// The `u64` ID of the active context.
    fn extra_ctx_get_current_id(&self) -> u64;

    /// Sets the active extra context to the one identified by the given ID.
    ///
    /// All subsequent `extra_ctx_*` operations will be directed to this context
    /// until it is changed or unset.
    ///
    /// # Parameters
    /// - `idx`: The `u64` ID of the context to set as active.
    ///
    /// # Returns
    /// - `Ok(())` on success.
    ///
    /// # Errors
    /// - `ContextIndexError` if no context with the specified `idx` exists.
    fn extra_ctx_set_current_id(&mut self, idx: u64) -> Result<(), ContextIndexError>;

    /// Unsets the currently active extra context.
    ///
    /// After this operation, `extra_ctx_get_current_id` will return `0`,
    /// indicating that no extra context is active.
    ///
    /// # Returns
    /// - `Ok(())` if a context was active and has now been unset.
    ///
    /// # Errors
    /// - `ContextIndexError` if no extra context was active to begin with.
    fn extra_ctx_unset_current_id(&mut self) -> Result<(), ContextIndexError>;

    /// Adds a `Contextoid` node to the currently active extra context.
    ///
    /// This operation is directed to the context set by `extra_ctx_set_current_id`.
    ///
    /// # Parameters
    /// - `value`: The `Contextoid` instance to add to the graph.
    ///
    /// # Returns
    /// - `Ok(usize)` containing the unique index of the newly added node within the active context's graph.
    ///
    /// # Errors
    /// - `ContextIndexError` if no extra context is currently active.
    fn extra_ctx_add_node(
        &mut self,
        value: Contextoid<D, S, T, ST, SYM, VS, VT>,
    ) -> Result<usize, ContextIndexError>;

    /// Checks if a node with the given index exists in the currently active extra context.
    ///
    /// This operation is directed to the context set by `extra_ctx_set_current_id`.
    ///
    /// # Parameters
    /// - `index`: The index of the node to check for.
    ///
    /// # Returns
    /// - `true` if a node with the specified index exists in the active context.
    /// - `false` if the node does not exist or if no extra context is currently active.
    fn extra_ctx_contains_node(&self, index: usize) -> bool;

    /// Retrieves an immutable reference to a `Contextoid` from the currently active extra context.
    ///
    /// This operation is directed to the context set by `extra_ctx_set_current_id`.
    ///
    /// # Parameters
    /// - `index`: The index of the node to retrieve.
    ///
    /// # Returns
    /// - `Ok(&Contextoid<...>)` containing a reference to the node if found.
    ///
    /// # Errors
    /// - `ContextIndexError` if no extra context is active or if the `index` is out of bounds for the active context's graph.
    fn extra_ctx_get_node(
        &self,
        index: usize,
    ) -> Result<&Contextoid<D, S, T, ST, SYM, VS, VT>, ContextIndexError>;

    /// Removes a node by its index from the currently active extra context.
    ///
    /// This operation is directed to the context set by `extra_ctx_set_current_id`.
    /// Note that this will also remove all edges connected to the specified node.
    ///
    /// # Parameters
    /// - `index`: The index of the node to remove.
    ///
    /// # Returns
    /// - `Ok(())` if the node was successfully removed.
    ///
    /// # Errors
    /// - `ContextIndexError` if no extra context is active or if the `index` is out of bounds.
    fn extra_ctx_remove_node(&mut self, index: usize) -> Result<(), ContextIndexError>;

    /// Adds a directed edge between two nodes in the currently active extra context.
    ///
    /// The edge is created from node `a` to node `b`. This operation is directed
    /// to the context set by `extra_ctx_set_current_id`.
    ///
    /// # Parameters
    /// - `a`: The index of the source node.
    /// - `b`: The index of the target node.
    /// - `weight`: The `RelationKind` that describes the relationship between the nodes.
    ///
    /// # Returns
    /// - `Ok(())` if the edge was successfully added.
    ///
    /// # Errors
    /// - `ContextIndexError` if no extra context is active or if either `a` or `b` are invalid node indices.
    fn extra_ctx_add_edge(
        &mut self,
        a: usize,
        b: usize,
        weight: RelationKind,
    ) -> Result<(), ContextIndexError>;

    /// Checks if a directed edge exists between two nodes in the currently active extra context.
    ///
    /// The check is for an edge from node `a` to node `b`. This operation is directed
    /// to the context set by `extra_ctx_set_current_id`.
    ///
    /// # Parameters
    /// - `a`: The index of the source node.
    /// - `b`: The index of the target node.
    ///
    /// # Returns
    /// - `true` if a directed edge from `a` to `b` exists in the active context.
    /// - `false` if the edge does not exist, if either index is invalid, or if no
    ///   extra context is currently active.
    fn extra_ctx_contains_edge(&self, a: usize, b: usize) -> bool;

    /// Removes a directed edge between two nodes in the currently active extra context.
    ///
    /// This operation is directed to the context set by `extra_ctx_set_current_id`.
    ///
    /// # Parameters
    /// - `a`: The index of the source node of the edge to remove.
    /// - `b`: The index of the target node of the edge to remove.
    ///
    /// # Returns
    /// - `Ok(())` if the edge was successfully removed.
    ///
    /// # Errors
    /// - `ContextIndexError` if no extra context is active or if the edge does not exist.
    fn extra_ctx_remove_edge(&mut self, a: usize, b: usize) -> Result<(), ContextIndexError>;

    /// Returns the number of nodes in the currently active extra context's graph.
    ///
    /// This operation is directed to the context set by `extra_ctx_set_current_id`.
    ///
    /// # Returns
    /// - `Ok(usize)` containing the total number of nodes in the active context's graph.
    ///
    /// # Errors
    /// - `ContextIndexError` if no extra context is currently active.
    fn extra_ctx_size(&self) -> Result<usize, ContextIndexError>;

    /// Checks if the currently active extra context's graph is empty (contains no nodes).
    ///
    /// This operation is directed to the context set by `extra_ctx_set_current_id`.
    ///
    /// # Returns
    /// - `Ok(true)` if the active context's graph has zero nodes.
    /// - `Ok(false)` if it contains one or more nodes.
    ///
    /// # Errors
    /// - `ContextIndexError` if no extra context is currently active.
    fn extra_ctx_is_empty(&self) -> Result<bool, ContextIndexError>;

    /// Returns the total number of nodes in the currently active extra context's graph.
    ///
    /// This operation is directed to the context set by `extra_ctx_set_current_id`.
    ///
    /// # Returns
    /// - `Ok(usize)` containing the count of nodes in the active context's graph.
    ///
    /// # Errors
    /// - `ContextIndexError` if no extra context is currently active.
    fn extra_ctx_node_count(&self) -> Result<usize, ContextIndexError>;

    /// Returns the total number of edges in the currently active extra context's graph.
    ///
    /// This operation is directed to the context set by `extra_ctx_set_current_id`.
    ///
    /// # Returns
    /// - `Ok(usize)` containing the count of edges in the active context's graph.
    ///
    /// # Errors
    /// - `ContextIndexError` if no extra context is currently active.
    fn extra_ctx_edge_count(&self) -> Result<usize, ContextIndexError>;
}
