/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! DeepCausality is a Rust framework for dynamic causality. It enables fast, deterministic,
//! context-aware causal reasoning over complex multi-stage causal models, and stays correct
//! when both the data and the rules evolve at runtime.
//!
//! Why DeepCausality?
//! * Written in Rust with production-grade safety, reliability, and performance in mind.
//! * Provides recursive causal data structures that concisely express arbitrary complex causal structures.
//! * Threads context awareness across data-like, time-like, space-like, and spacetime-like entities stored within one or more context hypergraphs.
//! * Models complex tempo-spatial patterns through the Causal Monad and the Effect Propagation Process.
//! * Ships with a Causal State Machine (CSM) for pairing inference with action.
//!
//! See <https://docs.deepcausality.com/> for the documentation.
//!
mod alias;
mod errors;
mod extensions;
mod traits;
mod types;
mod utils;
pub mod utils_test;

// Re-Export Core Types
pub use deep_causality_core::{
    CausalEffectPropagationProcess, CausalFlow, CausalMonad, CausalityError, CausalityErrorEnum,
    EffectLog, EffectValue, PropagatingEffect, PropagatingProcess,
};

pub use deep_causality_haft::{LogAddEntry, LogAppend, LogEffect, LogSize};

//
// Aliases
//
pub use crate::alias::*;
//
// Error types
//
pub use crate::errors::*;
//
// Traits
//
// Adjustable Traits
pub use crate::traits::adjustable::{Adjustable, UncertainAdjustable};
// Assumeable Traits
pub use crate::traits::assumable::Assumable;
pub use crate::traits::assumable::AssumableReasoning;
// Causable Traits
pub use crate::traits::causable::stateful::StatefulMonadicCausable;
pub use crate::traits::causable::{Causable, MonadicCausable};
// Causable Graph Traits
pub use crate::traits::causable_graph::graph::CausableGraph;
pub use crate::traits::causable_graph::graph_reasoning::MonadicCausableGraphReasoning;
pub use crate::traits::causable_graph::graph_reasoning::stateful::StatefulMonadicCausableGraphReasoning;
pub use crate::traits::causable_graph::*;
pub use crate::traits::contextuable::coordinate::Coordinate;
pub use crate::traits::contextuable::datable::Datable;
pub use crate::traits::contextuable::datable_uncertain::UncertainDatable;
pub use crate::traits::contextuable::metric::Metric;
pub use crate::traits::contextuable::metric_coordinate::MetricCoordinate;
pub use crate::traits::contextuable::metric_tensor::MetricTensor4D;
pub use crate::traits::contextuable::space_temporal::SpaceTemporal;
pub use crate::traits::contextuable::space_temporal::SpaceTemporalInterval;
pub use crate::traits::contextuable::spatial::Spatial;
pub use crate::traits::contextuable::symbolic::Symbolic;
pub use crate::traits::contextuable::temporal::Temporal;
// contextuable Traits
pub use crate::traits::contextuable::Contextuable;
// Contextuable Graph Traits
pub use crate::traits::contextuable_graph::ContextuableGraph;
pub use crate::traits::contextuable_graph::ExtendableContextuableGraph;
// CSM traits
pub use crate::traits::csm_evaluable::CsmEvaluable;
// Identifiable Traits
pub use crate::traits::identifiable::Identifiable;
// Indexable Traits
pub use crate::traits::indexable::data_index_current::CurrentDataIndex;
pub use crate::traits::indexable::data_index_previous::PreviousDataIndex;
pub use crate::traits::indexable::data_indexable::DataIndexable;
pub use crate::traits::indexable::time_index_current::CurrentTimeIndex;
pub use crate::traits::indexable::time_index_previous::PreviousTimeIndex;
pub use crate::traits::indexable::time_indexable::TimeIndexable;
// Inferable Traits
pub use crate::traits::inferable::Inferable;
pub use crate::traits::inferable::InferableReasoning;
// Observable Traits
pub use crate::traits::observable::Observable;
pub use crate::traits::observable::ObservableReasoning;
// Scalar traits
pub use crate::traits::scalar::scalar_projector::ScalarProjector;
pub use crate::traits::scalar::scalar_value::ScalarValue;
// Transferable Trait
pub use crate::traits::transferable::Transferable;
//
// Types
//
// Causal types
pub use crate::types::causal_types::aggregate_logic::AggregateLogic;
pub use crate::types::causal_types::causal_type::CausaloidType;
pub use crate::types::causal_types::causaloid::Causaloid;
pub use crate::types::causal_types::causaloid_graph::CausaloidGraph;
pub use crate::types::causal_types::*;
// Default context node types.
pub use crate::types::context_node_types::data::Data;
pub use crate::types::context_node_types::data_uncertain::data_uncertain_bool::UncertainBooleanData;
pub use crate::types::context_node_types::data_uncertain::data_uncertain_f64::UncertainFloat64Data;
pub use crate::types::context_node_types::root::Root;
// Space context node types.
pub use crate::types::context_node_types::space::ecef_space::EcefSpace;
pub use crate::types::context_node_types::space::euclidean_space::EuclideanSpace;
pub use crate::types::context_node_types::space::geo_space::GeoSpace;
pub use crate::types::context_node_types::space::ned_space::NedSpace;
pub use crate::types::context_node_types::space::quaternion_space::QuaternionSpace;
pub use crate::types::context_node_types::space::space_kind::SpaceKind;
// Space time context node types.
pub use crate::types::context_node_types::space_time::euclidean_spacetime::EuclideanSpacetime;
pub use crate::types::context_node_types::space_time::lorentzian_spacetime::LorentzianSpacetime;
pub use crate::types::context_node_types::space_time::minkowski_spacetime::MinkowskiSpacetime;
pub use crate::types::context_node_types::space_time::space_time_kind::SpaceTimeKind;
pub use crate::types::context_node_types::space_time::tangent_spacetime::TangentSpacetime;
// Symbolic context node types.
pub use crate::types::context_node_types::symbol::base_symbol::BaseSymbol;
pub use crate::types::context_node_types::symbol::symbol_kind::SymbolKind;
// pub use crate::types::context_types::node_types::symbol::symbol_kind
// Symbolic spacetime context node types.
pub use crate::types::context_node_types::symbol_spacetime::causal_set_spacetime::CausalSetSpacetime;
pub use crate::types::context_node_types::symbol_spacetime::conformal_spacetime::ConformalSpacetime;
// Time context node types.
pub use crate::types::context_node_types::time::discrete_time::DiscreteTime;
pub use crate::types::context_node_types::time::entropic_time::EntropicTime;
pub use crate::types::context_node_types::time::euclidean_time::EuclideanTime;
pub use crate::types::context_node_types::time::lorentzian_time::LorentzianTime;
pub use crate::types::context_node_types::time::symbolic_time::{SymbolicTime, SymbolicTimeUnit};
pub use crate::types::context_node_types::time::time_kind::TimeKind;
// Context types
pub use crate::types::context_types::context_graph;
pub use crate::types::context_types::context_graph::Context;
pub use crate::types::context_types::contextoid::contextoid_type::*;
pub use crate::types::context_types::contextoid::*;
// Other context types
pub use crate::types::context_types::relation_kind::*;
pub use crate::types::context_types::time_scale::TimeScale;
// CSM types
pub use crate::types::csm_types::csm::CSM;
pub use crate::types::csm_types::csm_action::CausalAction;
pub use crate::types::csm_types::csm_parameter::action_parameter_value::ActionParameterValue;
pub use crate::types::csm_types::csm_parameter::proposed_action::ProposedAction;
pub use crate::types::csm_types::csm_parameter::uncertain_parameter::UncertainParameter;
pub use crate::types::csm_types::csm_state::CausalState;
// Generative types
pub use crate::types::generative_types::effect_system::{
    AuditableGraphGenerator, GraphGeneratableEffect, GraphGeneratableEffectSystem,
    GraphGeneratableEffectWitness,
};
pub use crate::types::generative_types::interpreter::{CausalSystemState, Interpreter};
pub use crate::types::generative_types::modification_log::{
    ModificationLog, ModificationLogEntry, OpStatus,
};
pub use crate::types::generative_types::operation::{OpTree, Operation};
// Model types
pub use crate::types::model_types::assumption::Assumption;
pub use crate::types::model_types::inference::Inference;
pub use crate::types::model_types::model::Model;
pub use crate::types::model_types::observation::Observation;

//
//Symbolic types
pub use crate::types::symbolic_types::symbolic_representation::SymbolicRepresentation;
pub use crate::types::symbolic_types::symbolic_result::SymbolicResult;
//

// Utils
//
pub use crate::utils::math_utils;
pub use crate::utils::monadic_collection_utils;
pub use crate::utils::time_utils;
// Causable Collection Traits
pub use traits::causable_collection::collection_accessor::CausableCollectionAccessor;
pub use traits::causable_collection::collection_reasoning::monadic_collection::MonadicCausableCollection;
pub use traits::causable_collection::collection_reasoning::stateful_monadic_collection::StatefulMonadicCausableCollection;

// Uncertainty types
pub use deep_causality_uncertain::Uncertain;
