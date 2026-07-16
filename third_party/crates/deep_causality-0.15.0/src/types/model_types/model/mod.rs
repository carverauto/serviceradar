/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
mod getters;
mod identifiable;
mod transferable;

use crate::traits::contextuable::space_temporal::SpaceTemporal;
use crate::traits::contextuable::spatial::Spatial;
use crate::traits::contextuable::temporal::Temporal;
use crate::{Assumption, Causaloid, Context, Contextoid, Datable, Identifiable, Symbolic};
use std::fmt::Debug;
use std::sync::{Arc, RwLock};

#[derive(Debug)]
pub struct Model<I, O, C>
where
    I: Default,
    O: Default + Debug,
    C: Clone,
{
    id: u64,
    author: String,
    description: String,
    assumptions: Option<Arc<Vec<Assumption>>>,
    /// The root causaloid of the model, encapsulating the main causal logic.
    ///
    /// The `Causaloid` is the core component that defines the causal reasoning mechanism
    /// of the model. It can be a singleton, a collection, or a complex graph of
    /// causal relationships.
    causaloid: Arc<Causaloid<I, O, (), Arc<RwLock<C>>>>,
    context: Option<Arc<RwLock<C>>>,
}

impl<I, O, C> Model<I, O, C>
where
    I: Default,
    O: Default + Debug,
    C: Clone,
{
    pub fn new(
        id: u64,
        author: &str,
        description: &str,
        assumptions: Option<Arc<Vec<Assumption>>>,
        causaloid: Arc<Causaloid<I, O, (), Arc<RwLock<C>>>>,
        context: Option<Arc<RwLock<C>>>,
    ) -> Self {
        Self {
            id,
            author: author.to_string(),
            description: description.to_string(),
            assumptions,
            causaloid,
            context,
        }
    }
}

#[allow(clippy::type_complexity)]
impl<I, O, D, S, T, ST, SYM, VS, VT> Model<I, O, Context<D, S, T, ST, SYM, VS, VT>>
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
    /// Evolves the model by applying a sequence of operations defined in an `OpTree`.
    ///
    /// This method uses the HKT-based `Interpreter` to execute the operations
    /// and returns a new `Model` instance reflecting the changes, along with a log of modifications.
    pub fn evolve(
        &self,
        op_tree: &crate::OpTree<
            I,
            O,
            Context<D, S, T, ST, SYM, VS, VT>,
            Contextoid<D, S, T, ST, SYM, VS, VT>,
        >,
    ) -> Result<(Self, crate::ModificationLog), crate::ModelValidationError> {
        // 1. Initialize the interpreter state with the current model's components.
        let mut state = crate::CausalSystemState::new();

        // Populate state with current context if it exists
        if let Some(ctx_arc) = &self.context {
            let ctx =
                ctx_arc
                    .read()
                    .map_err(|_| crate::ModelValidationError::InterpreterError {
                        reason: "Failed to read context lock".to_string(),
                    })?;

            state.contexts.insert(ctx.id(), ctx.clone());
        }

        // Populate state with current causaloid
        state
            .causaloids
            .insert(self.causaloid.id(), (*self.causaloid).clone());

        // 2. Create the Interpreter.
        let interpreter = crate::Interpreter::new();

        // 3. Execute the OpTree.
        let effect = interpreter.execute(op_tree, state);

        if let Some(err) = effect.error {
            return Err(err);
        }

        let final_state =
            effect
                .value
                .ok_or_else(|| crate::ModelValidationError::InterpreterError {
                    reason: "Unknown error: execution failed but no specific error was provided"
                        .to_string(),
                })?;

        let logs = effect.logs;

        // 4. Reconstruct the Model from the final state.
        let new_causaloid = final_state
            .causaloids
            .get(&self.causaloid.id())
            .cloned()
            .ok_or_else(|| crate::ModelValidationError::InterpreterError {
                reason: "Main causaloid lost during evolution".to_string(),
            })?;

        let new_context = if let Some(old_ctx) = &self.context {
            let old_id = old_ctx
                .read()
                .map_err(|_| crate::ModelValidationError::InterpreterError {
                    reason: "Context read lock poisoned".to_string(),
                })?
                .id();
            final_state.contexts.get(&old_id).cloned()
        } else {
            None
        };

        Ok((
            Self::new(
                self.id,
                &self.author,
                &self.description,
                self.assumptions.clone(),
                Arc::new(new_causaloid),
                new_context.map(|c| Arc::new(RwLock::new(c))),
            ),
            logs,
        ))
    }
}
