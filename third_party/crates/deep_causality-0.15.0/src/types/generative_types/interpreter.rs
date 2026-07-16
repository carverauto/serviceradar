/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! # Interpreter Module
//!
//! This module provides the execution engine for the HKT-based generative system.
//! It interprets operation trees (`OpTree`) and applies them to causal models within
//! the auditable effect system.
//!
//! ## Overview
//!
//! The interpreter follows a functional, stateless design:
//! - **Input**: An `OpTree` (tree of operations) and initial `CausalSystemState`
//! - **Output**: An `AuditableGraphGenerator` wrapping the final state and complete audit log
//! - **Execution**: Recursive tree walking with monadic composition
//!
//! ## Key Types
//!
//! - [`Interpreter`]: Stateless executor for operation trees
//! - [`CausalSystemState`]: Mutable state container holding causaloids and contexts
//!
//! ## Design Principles
//!
//! 1. **Stateless Execution**: The `Interpreter` has no internal state; all state is explicit
//! 2. **Monadic Composition**: Operations are composed using the HKT effect system
//! 3. **Complete Auditability**: Every operation produces detailed log entries
//! 4. **Error Propagation**: Errors short-circuit execution and are captured in the effect

use crate::{
    AuditableGraphGenerator, Causaloid, Context, Contextoid, GraphGeneratableEffect,
    GraphGeneratableEffectSystem, Identifiable, ModelValidationError, ModificationLog,
    ModificationLogEntry, OpStatus, OpTree, Operation,
};

use crate::{ContextuableGraph, Datable, SpaceTemporal, Spatial, Symbolic, Temporal};
use deep_causality_haft::{Effect3, Monad, Pure};
use std::collections::HashMap;
use std::fmt::Debug;
use std::sync::{Arc, RwLock};

/// Mutable state container for the causal system.
///
/// This struct holds all mutable state during operation execution:
/// - Causaloids indexed by ID
/// - Contexts indexed by ID
///
/// # Type Parameters
///
/// - `I`: Input generic
/// - `O`: Output generic
/// - `C`: Context generic
#[allow(clippy::type_complexity)]
pub struct CausalSystemState<I, O, C>
where
    I: Default,
    O: Default + Debug,
    C: Clone,
{
    pub causaloids: HashMap<u64, Causaloid<I, O, (), Arc<RwLock<C>>>>,
    pub contexts: HashMap<u64, C>,
}

impl<I, O, C> CausalSystemState<I, O, C>
where
    I: Default,
    O: Default + Debug,
    C: Clone,
{
    pub fn new() -> Self {
        Self {
            causaloids: HashMap::new(),
            contexts: HashMap::new(),
        }
    }
}

impl<I, O, C> Clone for CausalSystemState<I, O, C>
where
    I: Default,
    O: Default + Debug,
    C: Clone,
{
    fn clone(&self) -> Self {
        Self {
            causaloids: self.causaloids.clone(),
            contexts: self.contexts.clone(),
        }
    }
}

impl<I, O, C> Default for CausalSystemState<I, O, C>
where
    I: Default,
    O: Default + Debug,
    C: Clone,
{
    fn default() -> Self {
        Self::new()
    }
}

impl<I, O, C> std::fmt::Debug for CausalSystemState<I, O, C>
where
    I: Default,
    O: Default + Debug,
    C: Clone + std::fmt::Debug,
{
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CausalSystemState")
            .field("causaloids", &self.causaloids)
            .field("contexts", &self.contexts)
            .finish()
    }
}

pub struct Interpreter;

impl Default for Interpreter {
    fn default() -> Self {
        Self::new()
    }
}

impl Interpreter {
    pub fn new() -> Self {
        Self
    }

    /// Executes an operation tree, producing an auditable result.
    ///
    /// This is the main entry point for executing operations. It initializes
    /// the effect system and delegates to `walk` for recursive execution.
    ///
    /// # Arguments
    ///
    /// - `tree`: The operation tree to execute
    /// - `initial_state`: The starting state of the causal system
    ///
    /// # Returns
    ///
    /// An `AuditableGraphGenerator` containing:
    /// - The final state (or `None` if an error occurred)
    /// - Any error that prevented execution
    /// - Complete audit log of all operations
    #[allow(clippy::type_complexity)]
    #[allow(clippy::type_complexity)]
    pub fn execute<I, O, D, S, T, ST, SYM, VS, VT>(
        &self,
        tree: &OpTree<
            I,
            O,
            Context<D, S, T, ST, SYM, VS, VT>,
            Contextoid<D, S, T, ST, SYM, VS, VT>,
        >,
        initial_state: CausalSystemState<I, O, Context<D, S, T, ST, SYM, VS, VT>>,
    ) -> AuditableGraphGenerator<CausalSystemState<I, O, Context<D, S, T, ST, SYM, VS, VT>>>
    where
        I: Default + Clone,
        O: Default + Debug + Clone,
        D: Datable + Copy + Clone + PartialEq + std::fmt::Debug,
        S: Spatial<VS> + Clone + std::fmt::Debug,
        T: Temporal<VT> + Clone + std::fmt::Debug,
        ST: SpaceTemporal<VS, VT> + Clone + std::fmt::Debug,
        SYM: Symbolic + Clone + std::fmt::Debug,
        VS: Clone + std::fmt::Debug,
        VT: Clone + std::fmt::Debug,
    {
        self.walk(tree, initial_state)
    }

    /// Recursively walks and executes an operation tree node.
    ///
    /// This method handles the recursive traversal of the operation tree,
    /// applying each operation and composing the results monadically.
    #[allow(clippy::only_used_in_recursion)]
    #[allow(clippy::type_complexity)]
    fn walk<I, O, D, S, T, ST, SYM, VS, VT>(
        &self,
        op_node: &OpTree<
            I,
            O,
            Context<D, S, T, ST, SYM, VS, VT>,
            Contextoid<D, S, T, ST, SYM, VS, VT>,
        >,
        state: CausalSystemState<I, O, Context<D, S, T, ST, SYM, VS, VT>>,
    ) -> AuditableGraphGenerator<CausalSystemState<I, O, Context<D, S, T, ST, SYM, VS, VT>>>
    where
        I: Default + Clone,
        O: Default + Debug + Clone,
        D: Datable + Copy + Clone + PartialEq + std::fmt::Debug,
        S: Spatial<VS> + Clone + std::fmt::Debug,
        T: Temporal<VT> + Clone + std::fmt::Debug,
        ST: SpaceTemporal<VS, VT> + Clone + std::fmt::Debug,
        SYM: Symbolic + Clone + std::fmt::Debug,
        VS: Clone + std::fmt::Debug,
        VT: Clone + std::fmt::Debug,
    {
        type Witness = <GraphGeneratableEffectSystem as Effect3>::HktWitness;

        match op_node.value() {
            Operation::Sequence => {
                // Use a monadic fold to execute children in sequence.
                // `bind` will handle error short-circuiting and log aggregation.
                op_node.children().iter().fold(
                    <Witness as Pure<Witness>>::pure(state), // Start with the current state in a pure effect
                    |acc_effect, child_node| {
                        <Witness as Monad<Witness>>::bind(acc_effect, |current_state| {
                            self.walk(child_node, current_state)
                        })
                    },
                )
            }

            Operation::CreateContext { id, name, capacity } => {
                let mut new_state = state.clone();
                let mut logs = ModificationLog::new();
                if new_state.contexts.contains_key(id) {
                    // FAILURE
                    logs.add_entry(ModificationLogEntry::new(
                        "CreateContext",
                        id.to_string(),
                        OpStatus::Failure,
                        format!("Context with ID {} already exists.", id),
                    ));

                    GraphGeneratableEffect {
                        value: Some(state),
                        error: Some(ModelValidationError::DuplicateContextId { id: *id }),
                        logs,
                    }
                } else {
                    // SUCCESS
                    let new_context = Context::with_capacity(*id, name.as_str(), *capacity);
                    new_state.contexts.insert(*id, new_context);

                    logs.add_entry(ModificationLogEntry::new(
                        "CreateContext",
                        id.to_string(),
                        OpStatus::Success,
                        format!("Context '{}' created.", name),
                    ));

                    GraphGeneratableEffect {
                        value: Some(new_state),
                        error: None,
                        logs,
                    }
                }
            }

            Operation::AddContextoidToContext {
                context_id,
                contextoid,
            } => {
                let mut new_state = state.clone();
                let mut logs = ModificationLog::new();

                if let Some(context) = new_state.contexts.get_mut(context_id) {
                    if context.get_node_index_by_id(contextoid.id()).is_some() {
                        logs.add_entry(ModificationLogEntry::new(
                            "AddContextoidToContext",
                            contextoid.id().to_string(),
                            OpStatus::Failure,
                            "Contextoid already exists.",
                        ));

                        GraphGeneratableEffect {
                            value: Some(state),
                            error: Some(ModelValidationError::AddContextoidError {
                                err: "Duplicate contextoid ID".to_string(),
                            }),
                            logs,
                        }
                    } else {
                        // Use ContextuableGraph trait method
                        match context.add_node(contextoid.clone()) {
                            Ok(_) => {
                                logs.add_entry(ModificationLogEntry::new(
                                    "AddContextoidToContext",
                                    context_id.to_string(),
                                    OpStatus::Success,
                                    "Contextoid added.",
                                ));
                                GraphGeneratableEffect {
                                    value: Some(new_state),
                                    error: None,
                                    logs,
                                }
                            }
                            Err(e) => GraphGeneratableEffect {
                                value: Some(state),
                                error: Some(ModelValidationError::AddContextoidError {
                                    err: e.to_string(),
                                }),
                                logs,
                            },
                        }
                    }
                } else {
                    logs.add_entry(ModificationLogEntry::new(
                        "AddContextoidToContext",
                        context_id.to_string(),
                        OpStatus::Failure,
                        "Target context not found.",
                    ));
                    GraphGeneratableEffect {
                        value: Some(state),
                        error: Some(ModelValidationError::TargetContextNotFound {
                            id: *context_id,
                        }),
                        logs,
                    }
                }
            }

            Operation::CreateCausaloid(id, causaloid) => {
                let mut new_state = state.clone();
                let mut logs = ModificationLog::new();

                if new_state.causaloids.contains_key(id) {
                    logs.add_entry(ModificationLogEntry::new(
                        "CreateCausaloid".to_string(),
                        id.to_string(),
                        OpStatus::Failure,
                        format!("Causaloid with ID {} already exists.", id),
                    ));
                    GraphGeneratableEffect {
                        value: Some(state),
                        error: Some(ModelValidationError::DuplicateCausaloidID { id: *id }),
                        logs,
                    }
                } else {
                    new_state.causaloids.insert(*id, causaloid.clone());

                    logs.add_entry(ModificationLogEntry::new(
                        "CreateCausaloid".to_string(),
                        id.to_string(),
                        OpStatus::Success,
                        "Causaloid created.".to_string(),
                    ));

                    GraphGeneratableEffect {
                        value: Some(new_state),
                        error: None,
                        logs,
                    }
                }
            }

            Operation::UpdateCausaloid(id, causaloid) => {
                let mut new_state = state.clone();
                let mut logs = ModificationLog::new();

                if new_state.causaloids.contains_key(id) {
                    new_state.causaloids.insert(*id, causaloid.clone());
                    logs.add_entry(ModificationLogEntry::new(
                        "UpdateCausaloid",
                        id.to_string(),
                        OpStatus::Success,
                        "Causaloid updated.",
                    ));
                    GraphGeneratableEffect {
                        value: Some(new_state),
                        error: None,
                        logs,
                    }
                } else {
                    logs.add_entry(ModificationLogEntry::new(
                        "UpdateCausaloid",
                        id.to_string(),
                        OpStatus::Failure,
                        format!("Causaloid with ID {} not found", id),
                    ));
                    GraphGeneratableEffect {
                        value: Some(state),
                        error: Some(ModelValidationError::UpdateNodeError {
                            err: format!("Causaloid with ID {} not found", id),
                        }),
                        logs,
                    }
                }
            }

            Operation::DeleteCausaloid(id) => {
                let mut new_state = state.clone();
                let mut logs = ModificationLog::new();

                if new_state.causaloids.remove(id).is_some() {
                    logs.add_entry(ModificationLogEntry::new(
                        "DeleteCausaloid",
                        id.to_string(),
                        OpStatus::Success,
                        "Causaloid deleted.",
                    ));
                    GraphGeneratableEffect {
                        value: Some(new_state),
                        error: None,
                        logs,
                    }
                } else {
                    logs.add_entry(ModificationLogEntry::new(
                        "DeleteCausaloid",
                        id.to_string(),
                        OpStatus::Failure,
                        format!("Causaloid with ID {} not found.", id),
                    ));
                    GraphGeneratableEffect {
                        value: Some(state),
                        error: Some(ModelValidationError::RemoveNodeError {
                            err: format!("Causaloid with ID {} not found.", id),
                        }),
                        logs,
                    }
                }
            }

            Operation::CreateExtraContext {
                context_id,
                extra_context_id,
                capacity,
            } => {
                let mut new_state = state.clone();
                let mut logs = ModificationLog::new();

                // Validate parent context existence
                if !new_state.contexts.contains_key(context_id) {
                    logs.add_entry(ModificationLogEntry::new(
                        "CreateExtraContext",
                        context_id.to_string(),
                        OpStatus::Failure,
                        "Parent context not found.",
                    ));
                    GraphGeneratableEffect {
                        value: Some(state),
                        error: Some(ModelValidationError::TargetContextNotFound {
                            id: *context_id,
                        }),
                        logs,
                    }
                } else if new_state.contexts.contains_key(extra_context_id) {
                    logs.add_entry(ModificationLogEntry::new(
                        "CreateExtraContext",
                        extra_context_id.to_string(),
                        OpStatus::Failure,
                        format!("Context with ID {} already exists.", extra_context_id),
                    ));
                    GraphGeneratableEffect {
                        value: Some(state),
                        error: Some(ModelValidationError::DuplicateContextId {
                            id: *extra_context_id,
                        }),
                        logs,
                    }
                } else {
                    let name = format!("ExtraContext_{}", extra_context_id);
                    let new_context =
                        Context::with_capacity(*extra_context_id, name.as_str(), *capacity);
                    new_state.contexts.insert(*extra_context_id, new_context);

                    logs.add_entry(ModificationLogEntry::new(
                        "CreateExtraContext",
                        extra_context_id.to_string(),
                        OpStatus::Success,
                        format!("Extra context {} created.", extra_context_id),
                    ));

                    GraphGeneratableEffect {
                        value: Some(new_state),
                        error: None,
                        logs,
                    }
                }
            }
            Operation::UpdateContext { id, new_name } => {
                let mut new_state = state.clone();
                let mut logs = ModificationLog::new();

                if let Some(context) = new_state.contexts.get_mut(id) {
                    if let Some(name) = new_name {
                        context.set_name(name.clone());
                    }

                    logs.add_entry(ModificationLogEntry::new(
                        "UpdateContext",
                        id.to_string(),
                        OpStatus::Success,
                        "Context updated.",
                    ));

                    GraphGeneratableEffect {
                        value: Some(new_state),
                        error: None,
                        logs,
                    }
                } else {
                    logs.add_entry(ModificationLogEntry::new(
                        "UpdateContext",
                        id.to_string(),
                        OpStatus::Failure,
                        format!("Context with ID {} not found", id),
                    ));
                    GraphGeneratableEffect {
                        value: Some(state),
                        error: Some(ModelValidationError::TargetContextNotFound { id: *id }),
                        logs,
                    }
                }
            }

            Operation::DeleteContext(id) => {
                let mut new_state = state.clone();
                let mut logs = ModificationLog::new();

                if new_state.contexts.remove(id).is_some() {
                    logs.add_entry(ModificationLogEntry::new(
                        "DeleteContext",
                        id.to_string(),
                        OpStatus::Success,
                        "Context deleted.",
                    ));
                    GraphGeneratableEffect {
                        value: Some(new_state),
                        error: None,
                        logs,
                    }
                } else {
                    logs.add_entry(ModificationLogEntry::new(
                        "DeleteContext",
                        id.to_string(),
                        OpStatus::Failure,
                        format!("Context with ID {} not found", id),
                    ));
                    GraphGeneratableEffect {
                        value: Some(state),
                        error: Some(ModelValidationError::TargetContextNotFound { id: *id }),
                        logs,
                    }
                }
            }

            Operation::UpdateContextoidInContext {
                context_id,
                existing_contextoid,
                new_contextoid,
            } => {
                let mut new_state = state.clone();
                let mut logs = ModificationLog::new();

                if let Some(context) = new_state.contexts.get_mut(context_id) {
                    match context.update_node(*existing_contextoid, new_contextoid.clone()) {
                        Ok(_) => {
                            logs.add_entry(ModificationLogEntry::new(
                                "UpdateContextoidInContext",
                                context_id.to_string(),
                                OpStatus::Success,
                                "Contextoid updated.",
                            ));
                            GraphGeneratableEffect {
                                value: Some(new_state),
                                error: None,
                                logs,
                            }
                        }
                        Err(e) => {
                            logs.add_entry(ModificationLogEntry::new(
                                "UpdateContextoidInContext",
                                context_id.to_string(),
                                OpStatus::Failure,
                                format!("Failed to update contextoid: {}", e),
                            ));
                            GraphGeneratableEffect {
                                value: Some(state),
                                error: Some(ModelValidationError::UpdateNodeError {
                                    err: e.to_string(),
                                }),
                                logs,
                            }
                        }
                    }
                } else {
                    logs.add_entry(ModificationLogEntry::new(
                        "UpdateContextoidInContext",
                        context_id.to_string(),
                        OpStatus::Failure,
                        "Target context not found.",
                    ));
                    GraphGeneratableEffect {
                        value: Some(state),
                        error: Some(ModelValidationError::TargetContextNotFound {
                            id: *context_id,
                        }),
                        logs,
                    }
                }
            }

            Operation::DeleteContextoidFromContext {
                context_id,
                contextoid_id,
            } => {
                let mut new_state = state.clone();
                let mut logs = ModificationLog::new();

                if let Some(context) = new_state.contexts.get_mut(context_id) {
                    match context.remove_node(*contextoid_id) {
                        Ok(_) => {
                            logs.add_entry(ModificationLogEntry::new(
                                "DeleteContextoidFromContext",
                                context_id.to_string(),
                                OpStatus::Success,
                                "Contextoid deleted.",
                            ));
                            GraphGeneratableEffect {
                                value: Some(new_state),
                                error: None,
                                logs,
                            }
                        }
                        Err(e) => {
                            logs.add_entry(ModificationLogEntry::new(
                                "DeleteContextoidFromContext",
                                context_id.to_string(),
                                OpStatus::Failure,
                                format!("Failed to delete contextoid: {}", e),
                            ));
                            GraphGeneratableEffect {
                                value: Some(state),
                                error: Some(ModelValidationError::RemoveNodeError {
                                    err: e.to_string(),
                                }),
                                logs,
                            }
                        }
                    }
                } else {
                    logs.add_entry(ModificationLogEntry::new(
                        "DeleteContextoidFromContext",
                        context_id.to_string(),
                        OpStatus::Failure,
                        "Target context not found.",
                    ));
                    GraphGeneratableEffect {
                        value: Some(state),
                        error: Some(ModelValidationError::TargetContextNotFound {
                            id: *context_id,
                        }),
                        logs,
                    }
                }
            }

            Operation::NoOp => <Witness as Pure<Witness>>::pure(state), // No change, just pass state through.
        }
    }
}
