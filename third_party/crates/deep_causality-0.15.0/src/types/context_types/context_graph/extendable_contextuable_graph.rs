/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use ultragraph::*;

use crate::{
    Context, ContextIndexError, Contextoid, Datable, ExtendableContextuableGraph, RelationKind,
    SpaceTemporal, Spatial, Symbolic, Temporal,
};

#[allow(clippy::type_complexity)]
impl<D, S, T, ST, SYM, VS, VT> ExtendableContextuableGraph<D, S, T, ST, SYM, VS, VT>
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
    fn extra_ctx_add_new(&mut self, capacity: usize, default: bool) -> u64 {
        // This now acts as a wrapper, generating a new ID and calling the specific implementation.
        let new_id = self.number_of_extra_contexts + 1;
        self.extra_ctx_add_new_with_id(new_id, capacity, default)
            .expect("Failed to add new extra context with generated ID");
        new_id
    }

    fn extra_ctx_add_new_with_id(
        &mut self,
        id: u64,
        capacity: usize,
        default: bool,
    ) -> Result<(), ContextIndexError> {
        // Ensure the extra_contexts map exists, creating it if it's the first time.
        let extra_contexts = self.extra_contexts.get_or_insert_with(Default::default);

        // Check for a duplicate ID to prevent overwriting an existing context.
        if extra_contexts.contains_key(&id) {
            return Err(ContextIndexError(format!(
                "Extra context with ID {id} already exists."
            )));
        }

        // Create and insert the new context graph.
        let new_extra_context = UltraGraphWeighted::with_capacity(capacity, None);
        extra_contexts.insert(id, new_extra_context);

        // Update metadata.
        self.number_of_extra_contexts += 1;
        if default {
            self.extra_context_id = id;
        }

        Ok(())
    }

    fn extra_ctx_check_exists(&self, idx: u64) -> bool {
        if let Some(extra_contexts) = &self.extra_contexts {
            extra_contexts.contains_key(&idx)
        } else {
            false
        }
    }

    fn extra_ctx_get_current_id(&self) -> u64 {
        self.extra_context_id
    }

    fn extra_ctx_set_current_id(&mut self, idx: u64) -> Result<(), ContextIndexError> {
        if self.extra_ctx_check_exists(idx) {
            self.extra_context_id = idx;
            Ok(())
        } else {
            Err(ContextIndexError(format!(
                "Cannot set current extra context. ID {idx} does not exist."
            )))
        }
    }

    fn extra_ctx_unset_current_id(&mut self) -> Result<(), ContextIndexError> {
        if self.extra_context_id == 0 {
            return Err(ContextIndexError(
                "Cannot unset current extra context. No context is set.".to_string(),
            ));
        }
        self.extra_context_id = 0;
        Ok(())
    }

    fn extra_ctx_add_node(
        &mut self,
        value: Contextoid<D, S, T, ST, SYM, VS, VT>,
    ) -> Result<usize, ContextIndexError> {
        if let Some(extra_contexts) = self.extra_contexts.as_mut() {
            if let Some(current_ctx) = extra_contexts.get_mut(&self.extra_context_id) {
                let index = match current_ctx.add_node(value) {
                    Ok(index) => index,
                    Err(e) => {
                        return Err(ContextIndexError(e.to_string()));
                    }
                };

                Ok(index)
            } else {
                Err(ContextIndexError(format!(
                    "Cannot add node. Current extra context with ID {} not found.",
                    self.extra_context_id
                )))
            }
        } else {
            Err(ContextIndexError(
                "Cannot add node. No extra contexts have been created.".to_string(),
            ))
        }
    }

    fn extra_ctx_contains_node(&self, index: usize) -> bool {
        if let Some(extra_contexts) = self.extra_contexts.as_ref() {
            if let Some(current_ctx) = extra_contexts.get(&self.extra_context_id) {
                current_ctx.contains_node(index)
            } else {
                false
            }
        } else {
            false
        }
    }

    fn extra_ctx_get_node(
        &self,
        index: usize,
    ) -> Result<&Contextoid<D, S, T, ST, SYM, VS, VT>, ContextIndexError> {
        if let Some(extra_contexts) = self.extra_contexts.as_ref() {
            if let Some(current_ctx) = extra_contexts.get(&self.extra_context_id) {
                current_ctx.get_node(index).ok_or_else(|| {
                    ContextIndexError(format!(
                        "Node with index {} not found in current extra context with ID {}.",
                        index, self.extra_context_id
                    ))
                })
            } else {
                Err(ContextIndexError(format!(
                    "Cannot get node. Current extra context with ID {} not found.",
                    self.extra_context_id
                )))
            }
        } else {
            Err(ContextIndexError(
                "Cannot get node. No extra contexts have been created.".to_string(),
            ))
        }
    }

    fn extra_ctx_remove_node(&mut self, index: usize) -> Result<(), ContextIndexError> {
        if let Some(extra_contexts) = self.extra_contexts.as_mut() {
            if let Some(current_ctx) = extra_contexts.get_mut(&self.extra_context_id) {
                current_ctx
                    .remove_node(index)
                    .map_err(|e| ContextIndexError(e.to_string()))
            } else {
                Err(ContextIndexError(format!(
                    "Cannot remove node. Current extra context with ID {} not found.",
                    self.extra_context_id
                )))
            }
        } else {
            Err(ContextIndexError(
                "Cannot remove node. No extra contexts have been created.".to_string(),
            ))
        }
    }

    fn extra_ctx_add_edge(
        &mut self,
        a: usize,
        b: usize,
        weight: RelationKind,
    ) -> Result<(), ContextIndexError> {
        if let Some(extra_contexts) = self.extra_contexts.as_mut() {
            if let Some(current_ctx) = extra_contexts.get_mut(&self.extra_context_id) {
                let weight_value = weight as u64;
                current_ctx
                    .add_edge(a, b, weight_value)
                    .map_err(|e| ContextIndexError(e.to_string()))
            } else {
                Err(ContextIndexError(format!(
                    "Cannot add edge. Current extra context with ID {} not found.",
                    self.extra_context_id
                )))
            }
        } else {
            Err(ContextIndexError(
                "Cannot add edge. No extra contexts have been created.".to_string(),
            ))
        }
    }

    fn extra_ctx_contains_edge(&self, a: usize, b: usize) -> bool {
        // The most direct way is to get the context first.
        // If we can't get it for any reason, we can't check for an edge.
        if let Some(extra_contexts) = self.extra_contexts.as_ref() {
            if let Some(current_ctx) = extra_contexts.get(&self.extra_context_id) {
                // Now that we have a valid context, we can check for the edge.
                // The underlying ultragraph's `contains_edge` is robust and will
                // return false if the nodes don't exist.
                current_ctx.contains_edge(a, b)
            } else {
                // The map exists, but the current ID is invalid.
                false
            }
        } else {
            // The map itself doesn't exist.
            false
        }
    }

    fn extra_ctx_remove_edge(&mut self, a: usize, b: usize) -> Result<(), ContextIndexError> {
        // 1. Test if a valid context is available
        if let Some(extra_contexts) = self.extra_contexts.as_mut() {
            if let Some(current_ctx) = extra_contexts.get_mut(&self.extra_context_id) {
                // We have a valid context, now check the nodes.

                // 2. Test if node `a` exists
                if !current_ctx.contains_node(a) {
                    return Err(ContextIndexError(format!(
                        "Cannot remove edge: source node with index {} does not exist in current extra context with ID {}.",
                        a, self.extra_context_id
                    )));
                }

                // 3. Test if node `b` exists
                if !current_ctx.contains_node(b) {
                    return Err(ContextIndexError(format!(
                        "Cannot remove edge: target node with index {} does not exist in current extra context with ID {}.",
                        b, self.extra_context_id
                    )));
                }

                // 4. Try to remove the edge.
                // At this point, we know the nodes exist, so an error from the underlying
                // graph call means the edge itself does not exist.
                current_ctx
                    .remove_edge(a, b)
                    .map_err(|_| ContextIndexError(format!(
                        "Cannot remove edge: an edge from node {} to node {} does not exist in current extra context with ID {}.",
                        a, b, self.extra_context_id
                    )))
            } else {
                // Error: The map of contexts exists, but the current ID is invalid.
                Err(ContextIndexError(format!(
                    "Cannot remove edge. Current extra context with ID {} not found.",
                    self.extra_context_id
                )))
            }
        } else {
            // Error: The map of contexts itself doesn't exist.
            Err(ContextIndexError(
                "Cannot remove edge. No extra contexts have been created.".to_string(),
            ))
        }
    }

    fn extra_ctx_size(&self) -> Result<usize, ContextIndexError> {
        if let Some(extra_contexts) = self.extra_contexts.as_ref() {
            if let Some(current_ctx) = extra_contexts.get(&self.extra_context_id) {
                Ok(current_ctx.number_nodes())
            } else {
                Err(ContextIndexError(format!(
                    "Cannot get size. Current extra context with ID {} not found.",
                    self.extra_context_id
                )))
            }
        } else {
            Err(ContextIndexError(
                "Cannot get size. No extra contexts have been created.".to_string(),
            ))
        }
    }

    fn extra_ctx_is_empty(&self) -> Result<bool, ContextIndexError> {
        if let Some(extra_contexts) = self.extra_contexts.as_ref() {
            if let Some(current_ctx) = extra_contexts.get(&self.extra_context_id) {
                Ok(current_ctx.is_empty())
            } else {
                Err(ContextIndexError(format!(
                    "Cannot check if empty. Current extra context with ID {} not found.",
                    self.extra_context_id
                )))
            }
        } else {
            Err(ContextIndexError(
                "Cannot check if empty. No extra contexts have been created.".to_string(),
            ))
        }
    }

    fn extra_ctx_node_count(&self) -> Result<usize, ContextIndexError> {
        if let Some(extra_contexts) = self.extra_contexts.as_ref() {
            if let Some(current_ctx) = extra_contexts.get(&self.extra_context_id) {
                Ok(current_ctx.number_nodes())
            } else {
                Err(ContextIndexError(format!(
                    "Cannot get node count. Current extra context with ID {} not found.",
                    self.extra_context_id
                )))
            }
        } else {
            Err(ContextIndexError(
                "Cannot get node count. No extra contexts have been created.".to_string(),
            ))
        }
    }

    fn extra_ctx_edge_count(&self) -> Result<usize, ContextIndexError> {
        if let Some(extra_contexts) = self.extra_contexts.as_ref() {
            if let Some(current_ctx) = extra_contexts.get(&self.extra_context_id) {
                Ok(current_ctx.number_edges())
            } else {
                Err(ContextIndexError(format!(
                    "Cannot get edge count. Current extra context with ID {} not found.",
                    self.extra_context_id
                )))
            }
        } else {
            Err(ContextIndexError(
                "Cannot get edge count. No extra contexts have been created.".to_string(),
            ))
        }
    }
}
