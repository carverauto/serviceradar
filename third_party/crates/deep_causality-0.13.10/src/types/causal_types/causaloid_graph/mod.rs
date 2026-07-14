/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use ultragraph::UltraGraphWeighted;

use crate::{CausalGraph, IdentificationValue};

mod causable_graph;
mod default;
mod identifiable;

/// A specialized graph structure for representing and reasoning about causal relationships.
///
/// `CausaloidGraph` is a wrapper around an `ultragraph` graph, tailored for holding
/// nodes that implement the `Causable` trait. This structure allows for modeling
/// complex, non-linear causal systems where the activation of one cause can influence
/// others in a directed, potentially acyclic, manner.
///
/// The graph uses an adjacency matrix for its underlying storage, which provides
/// fast edge lookups but can be memory-intensive if the graph is sparse and has a
/// large capacity.
///
/// # Type Parameters
///
/// * `T`: The type of the nodes in the graph. It must implement `Causable` to allow
///   for causal reasoning, `PartialEq` for node comparison, `Clone` to manage graph
///   data, and `Display` for explanations. A common `T` is the `Causaloid` struct.
///
#[derive(Clone)]
pub struct CausaloidGraph<T: Clone> {
    id: IdentificationValue,
    graph: CausalGraph<T>,
}

impl<T: Clone> CausaloidGraph<T> {
    /// Creates a new `CausaloidGraph` with a default capacity.
    ///
    /// This constructor initializes the graph with a default capacity of 500 nodes.
    /// It utilizes an adjacency matrix for storage, which is suitable for dense graphs
    /// or graphs where the maximum number of nodes is known and not excessively large.
    ///
    /// # Returns
    ///
    pub fn new(id: IdentificationValue) -> Self {
        Self {
            id,
            graph: UltraGraphWeighted::with_capacity(500, None),
        }
    }

    /// Creates a new `CausaloidGraph` with a specified capacity.
    ///
    /// This constructor allows you to pre-allocate space for a given number of nodes,
    /// which can be beneficial for performance if the approximate size of the graph
    /// is known beforehand. The underlying storage uses an adjacency matrix.
    ///
    /// # Arguments
    ///
    /// * `capacity` - The maximum number of nodes the graph is expected to hold.
    ///
    pub fn new_with_capacity(id: IdentificationValue, capacity: usize) -> Self {
        Self {
            id,
            graph: UltraGraphWeighted::with_capacity(capacity, None),
        }
    }
}
