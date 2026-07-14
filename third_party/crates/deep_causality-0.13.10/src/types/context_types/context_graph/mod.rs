/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use std::collections::HashMap;

use ultragraph::*;

use crate::*;

mod contextuable_graph;
mod debug;
mod extendable_contextuable_graph;
mod identifiable;
mod indexable_data;
mod indexable_time;

type ExtraContext<D, S, T, ST, SYM, VS, VT> =
    UltraGraphWeighted<Contextoid<D, S, T, ST, SYM, VS, VT>, u64>;

type ExtraContextMap<D, S, T, ST, SYM, VS, VT> =
    HashMap<u64, ExtraContext<D, S, T, ST, SYM, VS, VT>>;

#[allow(clippy::type_complexity)]
pub struct Context<D, S, T, ST, SYM, VS, VT>
where
    D: Datable + Clone,
    S: Spatial<VS> + Clone,
    T: Temporal<VT> + Clone,
    ST: SpaceTemporal<VS, VT> + Clone,
    SYM: Symbolic + Clone,
    VS: Clone,
    VT: Clone,
{
    id: ContextId,
    name: String,
    base_context: UltraGraphWeighted<Contextoid<D, S, T, ST, SYM, VS, VT>, u64>,
    id_to_index_map: HashMap<ContextoidId, usize>,
    extra_contexts: Option<ExtraContextMap<D, S, T, ST, SYM, VS, VT>>,
    number_of_extra_contexts: u64,
    extra_context_id: u64,
    current_data_map: HashMap<usize, usize>,
    previous_data_map: HashMap<usize, usize>,
    current_index_map: HashMap<usize, usize>,
    previous_index_map: HashMap<usize, usize>,
}

impl<D, S, T, ST, SYM, VS, VT> Clone for Context<D, S, T, ST, SYM, VS, VT>
where
    D: Datable + Clone,
    S: Spatial<VS> + Clone,
    T: Temporal<VT> + Clone,
    ST: SpaceTemporal<VS, VT> + Clone,
    SYM: Symbolic + Clone,
    VS: Clone,
    VT: Clone,
{
    fn clone(&self) -> Self {
        Self {
            id: self.id,
            name: self.name.clone(),
            base_context: self.base_context.clone(),
            id_to_index_map: self.id_to_index_map.clone(),
            extra_contexts: self.extra_contexts.clone(),
            number_of_extra_contexts: self.number_of_extra_contexts,
            extra_context_id: self.extra_context_id,
            current_data_map: self.current_data_map.clone(),
            previous_data_map: self.previous_data_map.clone(),
            current_index_map: self.current_index_map.clone(),
            previous_index_map: self.previous_index_map.clone(),
        }
    }
}

impl<D, S, T, ST, SYM, VS, VT> Context<D, S, T, ST, SYM, VS, VT>
where
    D: Datable + Clone,
    S: Spatial<VS> + Clone,
    T: Temporal<VT> + Clone,
    ST: SpaceTemporal<VS, VT> + Clone,
    SYM: Symbolic + Clone,
    VS: Clone,
    VT: Clone,
{
    /// Creates a new context with the given node capacity.
    pub fn with_capacity(id: ContextId, name: &str, capacity: usize) -> Self {
        Self {
            id,
            name: name.to_string(),
            base_context: UltraGraphWeighted::with_capacity(capacity, None),
            id_to_index_map: HashMap::new(),
            extra_contexts: None,
            number_of_extra_contexts: 0,
            extra_context_id: 0,
            current_data_map: HashMap::new(),
            previous_data_map: HashMap::new(),
            current_index_map: HashMap::new(),
            previous_index_map: HashMap::new(),
        }
    }

    /// Returns the name of the context.
    pub fn name(&self) -> &str {
        self.name.as_str()
    }

    /// Sets the name of the context.
    pub fn set_name(&mut self, new_name: String) {
        self.name = new_name;
    }

    /// Returns the internal graph index for a given ContextoidId.
    /// This is useful for mapping external IDs to internal graph indices.
    pub fn get_node_index_by_id(&self, id: ContextoidId) -> Option<usize> {
        self.id_to_index_map.get(&id).copied()
    }
}
