/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use ultragraph::*;

use crate::benchmarks::data::Data;

pub fn build_linear_graph(k: usize) -> UltraGraph<Data> {
    let mut g: UltraGraphContainer<Data, _> = UltraGraph::with_capacity(k, None);

    let d = Data::default();

    let root_index = g.add_root_node(d).expect("Failed to add node");
    let mut previous_idx = root_index;

    for _ in 0..k {
        // add a new causaloid and set current idx to it
        let data = Data::default();
        let current_idx = g.add_node(data).expect("Failed to add node");

        // link current causaloid to previos causaloid
        g.add_edge(previous_idx, current_idx, ())
            .expect("Failed to add edge");

        previous_idx = current_idx;
    }

    g
}
