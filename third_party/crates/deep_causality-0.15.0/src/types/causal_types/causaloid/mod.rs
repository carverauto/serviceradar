/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! This module defines the `Causaloid` struct, the fundamental building block for representing
//! causal units within the DeepCausality framework.
//!
//! A `Causaloid` encapsulates a piece of causal logic, which can range from a simple
//! stateless function to a complex causal graph or a collection of other causaloids.
//! It supports both stateless and context-aware operations, allowing for flexible
//! and dynamic causal modeling.
//!
//! The module also provides various constructors to facilitate the creation of
//! different types of `Causaloid` instances, tailored to specific causal modeling needs.
use crate::MonadicCausable;
use crate::{
    AggregateLogic, CausalFn, CausaloidGraph, CausaloidType, ContextualCausalFn,
    IdentificationValue, LambdaEdges, NumericalValue,
};
use std::fmt::{Debug, Display, Formatter};
use std::marker::PhantomData;
use std::sync::Arc;

mod causable;
mod causable_stateful;
mod causable_utils;

mod display;
mod getters;
mod identifiable;
mod part_eq;

/// Type alias for a vector of `Causaloid`s.
///
/// This is typically used to represent a linear collection of causaloids,
/// which can then be encapsulated within a parent `Causaloid` of type `Collection`.
pub type CausalVec<I, O, STATE, CTX> = Vec<Causaloid<I, O, STATE, CTX>>;

/// Type alias for a graph of `Causaloid`s.
///
/// This represents a more complex, interconnected structure of causaloids,
/// which can be encapsulated within a parent `Causaloid` of type `Graph`.
pub type CausalGraph<I, O, STATE, CTX> = CausaloidGraph<Causaloid<I, O, STATE, CTX>>;

/// `Causaloid` is the fundamental building block for causal models in DeepCausality.
///
/// It represents a self-contained unit of causality, capable of encapsulating
/// various forms of causal logic:
/// - A single, stateless causal function (`CausaloidType::Singleton`).
/// - A single, context-aware causal function (`CausaloidType::Singleton` with `context`).
/// - A collection of other `Causaloid`s (`CausaloidType::Collection`).
/// - A hypergraph of other `Causaloid`s (`CausaloidType::Graph`).
///
/// `Causaloid`s are generic over their input (`I`), output (`O`), state (`STATE`), and context (`CTX`).
///
/// # Type Parameters
/// - `I`: The type of the input effect value.
/// - `O`: The type of the output effect value.
/// - `STATE`: The type for state management (e.g., internal state or aggregation state).
/// - `CTX`: The type for context, providing access to external data or environment.
pub struct Causaloid<I, O, STATE, CTX>
where
    I: Default,
    O: Default + Debug,
    STATE: Default + Clone,
    CTX: Clone,
{
    /// A unique identifier for this `Causaloid`.
    id: IdentificationValue,
    /// The type of causal logic encapsulated by this `Causaloid`.
    causal_type: CausaloidType,
    /// An optional stateless causal function, used when `causal_type` is `Singleton`.
    causal_fn: Option<CausalFn<I, O>>,
    /// An optional aggregation logic for `Collection` type causaloids.
    coll_aggregate_logic: Option<AggregateLogic>,
    /// An optional threshold value for `Collection` type causaloids.
    coll_threshold_value: Option<NumericalValue>,
    /// An optional context-aware causal function, used when `causal_type` is `Singleton`.
    context_causal_fn: Option<ContextualCausalFn<I, O, STATE, CTX>>,
    /// An optional shared context object, used by context-aware causaloids.
    context: Option<CTX>,
    /// An optional collection of child `Causaloid`s, used when `causal_type` is `Collection`.
    causal_coll: Option<Arc<Vec<Self>>>,
    /// An optional causal graph of child `Causaloid`s, used when `causal_type` is `Graph`.
    causal_graph: Option<Arc<CausaloidGraph<Self>>>,
    /// Optional per-edge Λ decoration slots for the causal graph, keyed by intrinsic edge
    /// identity (`(source, target)` node indices). An absent store or an absent slot is the
    /// identity Λ. Used when `causal_type` is `Graph`; applied at reconvergent joins as
    /// `join = ∇ ∘ (Λ₁ ⊗ Λ₂)` (`core.causaloid.inversion`).
    graph_lambda_edges: Option<Arc<LambdaEdges<O>>>,
    /// A human-readable description of the `Causaloid`.
    description: String,
    /// PhantomData to mark the usage of `I`, `O`, `STATE`, and `C` type parameters.
    _phantom: PhantomData<(I, O, STATE, CTX)>,
}

// Constructors
impl<I, O, STATE, CTX> Causaloid<I, O, STATE, CTX>
where
    I: Default,
    O: Default + Debug,
    STATE: Default + Clone,
    CTX: Clone,
{
    /// Creates a new singleton `Causaloid` with a stateless causal function.
    ///
    /// This constructor is used for `Causaloid`s that represent a single, atomic
    /// causal relationship defined by a pure function, without requiring any external context.
    ///
    /// # Arguments
    ///
    /// * `id` - A unique identifier for the causaloid.
    /// * `causal_fn` - The stateless function that defines the causaloid's reasoning logic.
    /// * `description` - A human-readable description of the causaloid.
    ///
    /// # Returns
    /// A new `Causaloid` instance of `CausaloidType::Singleton`.
    pub fn new(id: IdentificationValue, causal_fn: CausalFn<I, O>, description: &str) -> Self {
        Causaloid {
            id,
            causal_type: CausaloidType::Singleton,
            causal_fn: Some(causal_fn),
            context_causal_fn: None,
            context: None,
            coll_aggregate_logic: None,
            coll_threshold_value: None,
            causal_coll: None,
            causal_graph: None,
            graph_lambda_edges: None,
            description: description.to_string(),
            _phantom: PhantomData,
        }
    }

    /// Creates a new singleton `Causaloid` with a context-aware causal function.
    ///
    /// This constructor is used for `Causaloid`s that represent a single, atomic
    /// causal relationship whose logic depends on an external, shared `Context`.
    ///
    /// # Arguments
    ///
    /// * `id` - A unique identifier for the causaloid.
    /// * `context_causal_fn` - The context-aware stateless function for reasoning.
    /// * `context` - A shared context object accessible by the function.
    /// * `description` - A human-readable description of the causaloid.
    ///
    /// # Returns
    /// A new `Causaloid` instance of `CausaloidType::Singleton` with an associated context.
    pub fn new_with_context(
        id: IdentificationValue,
        context_causal_fn: ContextualCausalFn<I, O, STATE, CTX>,
        context: CTX,
        description: &str,
    ) -> Self {
        Causaloid {
            id,
            causal_type: CausaloidType::Singleton,
            causal_fn: None,
            context_causal_fn: Some(context_causal_fn),
            context: Some(context),
            coll_aggregate_logic: None,
            coll_threshold_value: None,
            causal_coll: None,
            causal_graph: None,
            graph_lambda_edges: None,
            description: description.to_string(),
            _phantom: PhantomData,
        }
    }
}

impl<I, O, STATE, CTX> Causaloid<I, O, STATE, CTX>
where
    I: Default,
    O: Default + Debug,
    STATE: Default + Clone,
    CTX: Clone,
{
    /// Creates a new `Causaloid` that encapsulates a linear collection of other `Causaloid`s.
    ///
    /// This allows treating a sequence of causal relationships as a single, composite causal unit.
    /// The collection can be evaluated individually, as part of another causal collection,
    /// or embedded into a causal graph.
    ///
    /// # Arguments
    ///
    /// * `id` - A unique identifier for the causaloid.
    /// * `causal_coll` - An `Arc` to a vector of child `Causaloid`s forming the collection.
    /// * `description` - A human-readable description of the causaloid.
    /// * `aggregate_logic` - The logic used to aggregate the results of the child causaloids.
    /// * `threshold_value` - A numerical threshold relevant to the aggregation logic.
    ///
    /// # Type Bounds
    /// The child `Causaloid`s within the collection must implement `Send`, `Sync`, and `'static`
    /// to ensure thread safety and static lifetime requirements for shared ownership.
    /// They must also implement `MonadicCausable<I, O>` for evaluation.
    ///
    /// # Returns
    /// A new `Causaloid` instance of `CausaloidType::Collection`.
    pub fn from_causal_collection(
        id: IdentificationValue,
        causal_coll: Arc<Vec<Causaloid<I, O, STATE, CTX>>>,
        description: &str,
        aggregate_logic: AggregateLogic,
        threshold_value: NumericalValue,
    ) -> Self
    where
        I: Send + Sync + 'static,
        O: Send + Sync + 'static,
        STATE: Send + Sync + 'static,
        CTX: Send + Sync + 'static,
        Causaloid<I, O, STATE, CTX>: MonadicCausable<I, O>,
    {
        Causaloid {
            id,
            causal_type: CausaloidType::Collection,
            causal_fn: None,
            context_causal_fn: None,
            context: None,
            coll_aggregate_logic: Some(aggregate_logic),
            coll_threshold_value: Some(threshold_value),
            causal_coll: Some(causal_coll),
            causal_graph: None,
            graph_lambda_edges: None,
            description: description.to_string(),
            _phantom: PhantomData,
        }
    }

    /// Creates a new `Causaloid` that encapsulates a linear collection of other `Causaloid`s
    /// with an associated shared context.
    ///
    /// This allows treating a sequence of causal relationships as a single, composite causal unit,
    /// where the evaluation of the collection can depend on an external, shared `Context`.
    ///
    /// # Arguments
    ///
    /// * `id` - A unique identifier for the causaloid.
    /// * `causal_coll` - An `Arc` to a vector of child `Causaloid`s forming the collection.
    /// * `context` - A shared context object accessible by the collection's logic.
    /// * `description` - A human-readable description of the causaloid.
    /// * `aggregate_logic` - The logic used to aggregate the results of the child causaloids.
    /// * `threshold_value` - A numerical threshold relevant to the aggregation logic.
    ///
    /// # Type Bounds
    /// The child `Causaloid`s within the collection must implement `Send`, `Sync`, and `'static`
    /// to ensure thread safety and static lifetime requirements for shared ownership.
    /// They must also implement `MonadicCausable<I, O>` for evaluation.
    ///
    /// # Returns
    /// A new `Causaloid` instance of `CausaloidType::Collection` with an associated context.
    pub fn from_causal_collection_with_context(
        id: IdentificationValue,
        causal_coll: Arc<Vec<Causaloid<I, O, STATE, CTX>>>,
        context: CTX,
        description: &str,
        aggregate_logic: AggregateLogic,
        threshold_value: NumericalValue,
    ) -> Self
    where
        I: Send + Sync + 'static,
        O: Send + Sync + 'static,
        STATE: Send + Sync + 'static,
        CTX: Send + Sync + 'static,
        Causaloid<I, O, STATE, CTX>: MonadicCausable<I, O>,
    {
        Causaloid {
            id,
            causal_type: CausaloidType::Collection,
            causal_fn: None,
            coll_aggregate_logic: Some(aggregate_logic),
            coll_threshold_value: Some(threshold_value),
            causal_coll: Some(causal_coll),
            causal_graph: None,
            graph_lambda_edges: None,
            description: description.to_string(),
            context: Some(context),
            context_causal_fn: None,
            _phantom: PhantomData,
        }
    }

    /// Creates a new `Causaloid` that encapsulates a causal graph of other `Causaloid`s.
    ///
    /// This allows treating a complex, interconnected network of causal relationships
    /// as a single, composite causal unit. The graph can be evaluated independently,
    /// or embedded into a larger causal structure.
    ///
    /// # Arguments
    ///
    /// * `id` - A unique identifier for the causaloid.
    /// * `description` - A human-readable description of the causaloid.
    /// * `causal_graph` - An `Arc` to a `CausaloidGraph` containing the interconnected child `Causaloid`s.
    ///
    /// # Returns
    /// A new `Causaloid` instance of `CausaloidType::Graph`.
    pub fn from_causal_graph(
        id: IdentificationValue,
        description: &str,
        causal_graph: Arc<CausaloidGraph<Self>>,
    ) -> Self {
        Causaloid {
            id,
            causal_type: CausaloidType::Graph,
            causal_fn: None,
            causal_coll: None,
            coll_aggregate_logic: None,
            coll_threshold_value: None,
            causal_graph: Some(causal_graph),
            graph_lambda_edges: None,
            description: description.to_string(),
            context: None,
            context_causal_fn: None,
            _phantom: PhantomData,
        }
    }

    /// Creates a new `Causaloid` that encapsulates a causal graph of other `Causaloid`s
    /// with an associated shared context.
    ///
    /// This allows treating a complex, interconnected network of causal relationships
    /// as a single, composite causal unit, where the evaluation of the graph can depend
    /// on an external, shared `Context`.
    ///
    /// # Arguments
    ///
    /// * `id` - A unique identifier for the causaloid.
    /// * `description` - A human-readable description of the causaloid.
    /// * `causal_graph` - An `Arc` to a `CausaloidGraph` containing the interconnected child `Causaloid`s.
    /// * `context` - A shared context object accessible by the graph's logic.
    ///
    /// # Returns
    /// A new `Causaloid` instance of `CausaloidType::Graph` with an associated context.
    pub fn from_causal_graph_with_context(
        id: IdentificationValue,
        description: &str,
        causal_graph: Arc<CausaloidGraph<Self>>,
        context: CTX,
    ) -> Self {
        Causaloid {
            id,
            causal_type: CausaloidType::Graph,
            causal_fn: None,
            causal_coll: None,
            coll_aggregate_logic: None,
            coll_threshold_value: None,
            causal_graph: Some(causal_graph),
            graph_lambda_edges: None,
            description: description.to_string(),
            context: Some(context),
            context_causal_fn: None,
            _phantom: PhantomData,
        }
    }

    /// Creates a new `Causaloid` encapsulating a causal graph whose edges carry per-edge Λ
    /// decoration slots.
    ///
    /// Λ is connection data (Hardy, arXiv:gr-qc/0509120): an optional transform attached to one
    /// identified edge, applied to the value flowing along that edge before the commutative merge
    /// `∇` at a reconvergent join — `join = ∇ ∘ (Λ₁ ⊗ Λ₂)`. Slots are keyed by intrinsic edge
    /// identity (`(source, target)` node indices), never by order; an absent slot is the identity
    /// Λ, so a graph built with an empty [`LambdaEdges`] evaluates exactly like one built with
    /// [`Causaloid::from_causal_graph`]. Machine-checked model: `core.causaloid.inversion`
    /// (`lean/DeepCausalityFormal/Core/Causaloid.lean`).
    ///
    /// # Arguments
    ///
    /// * `id` - A unique identifier for the causaloid.
    /// * `description` - A human-readable description of the causaloid.
    /// * `causal_graph` - An `Arc` to a `CausaloidGraph` containing the child `Causaloid`s.
    /// * `lambda_edges` - The identity-keyed per-edge Λ decoration slots for that graph.
    ///
    /// # Returns
    /// A new `Causaloid` instance of `CausaloidType::Graph` carrying the Λ decorations.
    pub fn from_causal_graph_with_lambda_edges(
        id: IdentificationValue,
        description: &str,
        causal_graph: Arc<CausaloidGraph<Self>>,
        lambda_edges: Arc<LambdaEdges<O>>,
    ) -> Self {
        Causaloid {
            id,
            causal_type: CausaloidType::Graph,
            causal_fn: None,
            causal_coll: None,
            coll_aggregate_logic: None,
            coll_threshold_value: None,
            causal_graph: Some(causal_graph),
            graph_lambda_edges: Some(lambda_edges),
            description: description.to_string(),
            context: None,
            context_causal_fn: None,
            _phantom: PhantomData,
        }
    }
}

impl<I, O, STATE, CTX> Clone for Causaloid<I, O, STATE, CTX>
where
    I: Default,
    O: Default + Debug,
    STATE: Default + Clone,
    CTX: Clone,
{
    fn clone(&self) -> Self {
        Self {
            id: self.id,
            causal_type: self.causal_type,
            causal_fn: self.causal_fn,
            coll_aggregate_logic: self.coll_aggregate_logic,
            coll_threshold_value: self.coll_threshold_value,
            context_causal_fn: self.context_causal_fn,
            context: self.context.clone(),
            causal_coll: self.causal_coll.clone(),
            causal_graph: self.causal_graph.clone(),
            graph_lambda_edges: self.graph_lambda_edges.clone(),
            description: self.description.clone(),
            _phantom: PhantomData,
        }
    }
}
