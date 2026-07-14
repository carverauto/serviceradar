/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use ultragraph::{GraphMut, GraphView};

use crate::{
    CausableGraph, MonadicCausable, MonadicCausableGraphReasoning, StatefulMonadicCausable,
    StatefulMonadicCausableGraphReasoning,
};
use crate::{CausalGraphIndexError, CausalityGraphError, Causaloid, CausaloidGraph};
use std::fmt::Debug;

// Marker trait to add default impl from MonadicCausableGraphReasoning
impl<V, PS, C> MonadicCausableGraphReasoning<V, PS, C> for CausaloidGraph<Causaloid<V, V, PS, C>>
where
    V: Default + Clone + Send + Sync + 'static + Debug,
    PS: Default + Clone + Send + Sync + 'static,
    C: Clone + Send + Sync + 'static,
    Causaloid<V, V, PS, C>: MonadicCausable<V, V>,
{
}

// Marker trait to add default impl from StatefulMonadicCausableGraphReasoning
impl<V, S, C> StatefulMonadicCausableGraphReasoning<V, S, C>
    for CausaloidGraph<Causaloid<V, V, S, C>>
where
    V: Default + Clone + Send + Sync + 'static + Debug,
    S: Default + Clone + Send + Sync + 'static + Debug,
    C: Clone + Send + Sync + 'static,
    Causaloid<V, V, S, C>: MonadicCausable<V, V> + StatefulMonadicCausable<V, V, S, C>,
{
}

impl<I, O, PS, C> CausableGraph<Causaloid<I, O, PS, C>> for CausaloidGraph<Causaloid<I, O, PS, C>>
where
    I: Default + Send + Sync + 'static,
    O: Default + Debug + Send + Sync + 'static,
    PS: Default + Clone + Send + Sync + 'static,
    C: Clone + Send + Sync + 'static,
    Causaloid<I, O, PS, C>: MonadicCausable<I, O>,
{
    fn is_frozen(&self) -> bool {
        self.graph.is_frozen()
    }

    fn freeze(&mut self) {
        self.graph.freeze()
    }

    fn unfreeze(&mut self) {
        self.graph.unfreeze()
    }

    fn get_graph(&self) -> &crate::traits::causable_graph::CausalGraph<Causaloid<I, O, PS, C>> {
        &self.graph
    }

    fn add_root_causaloid(
        &mut self,
        value: Causaloid<I, O, PS, C>,
    ) -> Result<usize, CausalityGraphError> {
        match self.graph.add_root_node(value) {
            Ok(index) => Ok(index),
            Err(e) => Err(CausalityGraphError(e.to_string())),
        }
    }

    fn contains_root_causaloid(&self) -> bool {
        self.graph.contains_root_node()
    }

    fn get_root_causaloid(&self) -> Option<&Causaloid<I, O, PS, C>> {
        self.graph.get_root_node()
    }

    fn get_root_index(&self) -> Option<usize> {
        self.graph.get_root_index()
    }

    fn get_last_index(&self) -> Result<usize, CausalityGraphError> {
        self.graph.get_last_index().ok_or_else(|| {
            CausalityGraphError("Failed to get last index. Graph might be empty".to_string())
        })
    }

    fn add_causaloid(
        &mut self,
        value: Causaloid<I, O, PS, C>,
    ) -> Result<usize, CausalityGraphError> {
        match self.graph.add_node(value) {
            Ok(index) => Ok(index),
            Err(e) => Err(CausalityGraphError(e.to_string())),
        }
    }

    fn contains_causaloid(&self, index: usize) -> bool {
        self.graph.contains_node(index)
    }

    fn get_causaloid(&self, index: usize) -> Option<&Causaloid<I, O, PS, C>> {
        self.graph.get_node(index)
    }

    fn remove_causaloid(&mut self, index: usize) -> Result<(), CausalGraphIndexError> {
        match self.graph.remove_node(index) {
            Ok(_) => Ok(()),
            Err(e) => Err(CausalGraphIndexError(e.to_string())),
        }
    }

    fn add_edge(&mut self, a: usize, b: usize) -> Result<(), CausalGraphIndexError> {
        match self.graph.add_edge(a, b, 0) {
            Ok(_) => Ok(()),
            Err(e) => Err(CausalGraphIndexError(e.to_string())),
        }
    }

    fn add_edg_with_weight(
        &mut self,
        a: usize,
        b: usize,
        weight: u64,
    ) -> Result<(), CausalGraphIndexError> {
        match self.graph.add_edge(a, b, weight) {
            Ok(_) => Ok(()),
            Err(e) => Err(CausalGraphIndexError(e.to_string())),
        }
    }

    fn contains_edge(&self, a: usize, b: usize) -> bool {
        self.graph.contains_edge(a, b)
    }

    fn remove_edge(&mut self, a: usize, b: usize) -> Result<(), CausalGraphIndexError> {
        match self.graph.remove_edge(a, b) {
            Ok(_) => Ok(()),
            Err(e) => Err(CausalGraphIndexError(e.to_string())),
        }
    }

    fn size(&self) -> usize {
        self.graph.number_nodes()
    }

    fn is_empty(&self) -> bool {
        self.graph.is_empty()
    }

    fn clear(&mut self) {
        let _ = self.graph.clear();
    }

    fn number_edges(&self) -> usize {
        self.graph.number_edges()
    }

    fn number_nodes(&self) -> usize {
        self.graph.number_nodes()
    }
}
