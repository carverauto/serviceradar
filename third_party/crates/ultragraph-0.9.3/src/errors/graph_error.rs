/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use std::fmt;

/// A lightweight, copyable, stack-allocated error type for the next_graph library
/// that provides context about the failure.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GraphError {
    /// An operation was attempted on a node index that does not exist or has been removed.
    NodeNotFound(usize),

    /// An edge could not be created, typically between two nodes.
    EdgeCreationError { source: usize, target: usize },

    /// An operation was attempted on an edge that does not exist.
    EdgeNotFoundError { source: usize, target: usize },

    /// The operation could not be completed because the graph contains a cycle.
    GraphContainsCycle,

    /// The operation could not be completed because the graph is not frozen.
    GraphNotFrozen,

    /// Operation not possible because the graph is frozen and cannot be mutated.
    GraphIsFrozen,

    /// Root node already exists
    RootNodeAlreadyExists,

    /// Graph algorithm error
    AlgorithmError(&'static str),
}

impl fmt::Display for GraphError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            Self::NodeNotFound(index) => {
                write!(
                    f,
                    "Node with index {index} not found; it may be out of bounds or have been removed."
                )
            }
            Self::EdgeCreationError { source, target } => {
                write!(
                    f,
                    "Edge from {source} to {target} could not be created; a node may not exist or the edge already exists."
                )
            }
            Self::EdgeNotFoundError { source, target } => {
                write!(f, "Edge from {source} to {target} not found.")
            }
            Self::GraphContainsCycle => {
                write!(f, "Operation failed because the graph contains a cycle.")
            }
            Self::GraphNotFrozen => {
                write!(
                    f,
                    "Operation not possible because the graph is not frozen. Call graph.freeze() first."
                )
            }
            Self::GraphIsFrozen => {
                write!(
                    f,
                    "Operation not possible because the graph is frozen and cannot be mutated. Call graph.unfreeze() first."
                )
            }
            Self::RootNodeAlreadyExists => {
                write!(f, "Root node already exists")
            }

            Self::AlgorithmError(e) => {
                write!(f, "AlgorithmError: {e}")
            }
        }
    }
}

// This makes GraphError a fully-fledged error type compatible with the Rust ecosystem.
impl std::error::Error for GraphError {}
