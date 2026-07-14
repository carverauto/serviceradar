/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use super::*;

#[allow(clippy::type_complexity)]
impl<I, O, PS, C> Causaloid<I, O, PS, C>
where
    I: Default,
    O: Default + Debug,
    PS: Default + Clone,
    C: Clone,
{
    pub fn id(&self) -> IdentificationValue {
        self.id
    }

    pub fn causal_type(&self) -> &CausaloidType {
        &self.causal_type
    }

    pub fn causal_fn(&self) -> Option<&CausalFn<I, O>> {
        self.causal_fn.as_ref()
    }

    pub fn context_causal_fn(&self) -> Option<&ContextualCausalFn<I, O, PS, C>> {
        self.context_causal_fn.as_ref()
    }

    pub fn context(&self) -> Option<&C> {
        self.context.as_ref()
    }

    pub fn causal_collection(&self) -> Option<&Arc<Vec<Causaloid<I, O, PS, C>>>> {
        self.causal_coll.as_ref()
    }

    pub fn causal_graph(&self) -> Option<&Arc<CausaloidGraph<Causaloid<I, O, PS, C>>>> {
        self.causal_graph.as_ref()
    }

    pub fn description(&self) -> &str {
        &self.description
    }

    pub fn coll_aggregate_logic(&self) -> Option<&AggregateLogic> {
        self.coll_aggregate_logic.as_ref()
    }

    pub fn coll_threshold_value(&self) -> Option<&NumericalValue> {
        self.coll_threshold_value.as_ref()
    }
}
