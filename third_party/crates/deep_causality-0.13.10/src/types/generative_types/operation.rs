/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! # Operation AST Module
//!
//! This module defines the core operation types for the HKT-based generative system.
//! It provides a declarative way to specify modifications to causal models through
//! an Abstract Syntax Tree (AST) representation.
//!
//! ## Overview
//!
//! The `Operation` enum represents all possible primitive operations and control flow
//! constructs that can be applied to a causal model. Operations are composed into trees
//! using the `OpTree` type alias, which is built on `ConstTree` from `deep_causality_ast`.
//!
//! ## Key Types
//!
//! - [`Operation`]: Enum representing all possible operations
//! - [`OpTree`]: Type alias for `ConstTree<Operation>`, representing operation trees
//!
//! ## Operation Categories
//!
//! ### Causaloid Operations
//! - `CreateCausaloid`: Create a new causaloid with a given ID
//! - `UpdateCausaloid`: Replace an existing causaloid
//! - `DeleteCausaloid`: Remove a causaloid by ID
//!
//! ### Context Operations
//! - `CreateContext`: Create a new base context
//! - `CreateExtraContext`: Add an extra context to an existing context
//! - `UpdateContext`: Modify context properties (e.g., name)
//! - `DeleteContext`: Remove a context by ID
//!
//! ### Contextoid Operations
//! - `AddContextoidToContext`: Add a contextoid node to a context graph
//! - `UpdateContextoidInContext`: Replace an existing contextoid
//! - `DeleteContextoidFromContext`: Remove a contextoid from a context
//!
//! ### Control Flow
//! - `Sequence`: Execute all child operations in order (fails if any child fails)
//! - `NoOp`: No operation (useful as placeholder or for conditional logic)
//!
//! ## Design Principles
//!
//! 1. **Operations as Data**: Operations are pure data structures that describe
//!    *what* to do, not *how* to do it. Execution is handled by the [`Interpreter`](crate::Interpreter).
//!
//! 2. **Composability**: Operations can be composed into trees using `Sequence`,
//!    enabling complex multi-step transformations.
//!
//! 3. **Type Safety**: All operations are strongly typed with generic parameters
//!    matching the causal model's type parameters.
//!
//! 4. **Auditability**: When executed by the `Interpreter`, operations produce
//!    detailed logs via the HKT effect system.

use crate::{Causaloid, CausaloidId, ContextId, ContextoidId};
use deep_causality_ast::ConstTree;
use std::fmt::Debug;
use std::sync::{Arc, RwLock};

/// Represents all possible operations that can be applied to a causal model.
///
/// This enum provides a declarative way to specify model transformations. Each variant
/// represents a primitive operation that can be executed by the [`Interpreter`](crate::Interpreter).
///
/// # Type Parameters
///
/// - `I`: Input effect value type
/// - `O`: Output effect value type
/// - `C`: Context type (e.g., `Context`)
/// - `N`: Node type (e.g., `Contextoid`)
#[derive(Clone, Debug)]
pub enum Operation<I, O, C, N>
where
    I: Default + Clone,
    O: Default + Clone + Debug,
    C: Clone,
    N: Clone,
{
    /// Creates a new causaloid with the specified ID.
    ///
    /// # Fields
    /// - `CausaloidId`: Unique identifier for the causaloid
    /// - `Causaloid`: The causaloid instance to create
    CreateCausaloid(CausaloidId, Causaloid<I, O, (), Arc<RwLock<C>>>),

    /// Updates an existing causaloid, replacing it with a new instance.
    ///
    /// # Fields
    /// - `CausaloidId`: ID of the causaloid to update
    /// - `Causaloid`: New causaloid instance
    UpdateCausaloid(CausaloidId, Causaloid<I, O, (), Arc<RwLock<C>>>),

    /// Deletes a causaloid by its ID.
    ///
    /// # Fields
    /// - `CausaloidId`: ID of the causaloid to delete
    DeleteCausaloid(CausaloidId),

    /// Creates a new base context.
    ///
    /// # Fields
    /// - `id`: Unique identifier for the context
    /// - `name`: Human-readable name
    /// - `capacity`: Initial capacity for the context graph
    CreateContext {
        id: ContextId,
        name: String,
        capacity: usize,
    },

    /// Creates an extra context within an existing context.
    ///
    /// # Fields
    /// - `context_id`: ID of the parent context
    /// - `extra_context_id`: ID for the new extra context
    /// - `capacity`: Initial capacity for the extra context
    CreateExtraContext {
        context_id: ContextId,
        extra_context_id: u64,
        capacity: usize,
    },

    /// Updates properties of an existing context.
    ///
    /// # Fields
    /// - `id`: ID of the context to update
    /// - `new_name`: Optional new name for the context
    UpdateContext {
        id: ContextId,
        new_name: Option<String>,
    },

    /// Deletes a context by its ID.
    ///
    /// # Fields
    /// - `ContextId`: ID of the context to delete
    DeleteContext(ContextId),

    /// Adds a node (contextoid) to a context's graph.
    ///
    /// # Fields
    /// - `context_id`: ID of the target context
    /// - `contextoid`: The node to add
    AddContextoidToContext {
        context_id: ContextId,
        contextoid: N,
    },

    /// Updates an existing node (contextoid) within a context.
    ///
    /// # Fields
    /// - `context_id`: ID of the containing context
    /// - `existing_contextoid`: ID of the node to replace
    /// - `new_contextoid`: New node instance
    UpdateContextoidInContext {
        context_id: ContextId,
        existing_contextoid: ContextoidId,
        new_contextoid: N,
    },

    /// Deletes a node (contextoid) from a context's graph.
    ///
    /// # Fields
    /// - `context_id`: ID of the containing context
    /// - `contextoid_id`: ID of the node to delete
    DeleteContextoidFromContext {
        context_id: ContextId,
        contextoid_id: ContextoidId,
    },

    /// Control flow: Execute all child operations in sequence.
    ///
    /// Fails if any child operation fails. Used as a root or intermediate
    /// node in an `OpTree` to compose multiple operations.
    Sequence,

    /// No operation. Useful as a placeholder or for conditional logic.
    NoOp,
}

/// Type alias for operation trees.
///
/// An `OpTree` is a `ConstTree` of `Operation` nodes, representing a hierarchical
/// structure of operations to be executed by the [`Interpreter`](crate::Interpreter).
pub type OpTree<I, O, C, N> = ConstTree<Operation<I, O, C, N>>;
