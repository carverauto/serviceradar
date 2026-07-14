/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::utils_test::test_utils;
use crate::{BaseCausaloid, CausableGraph, CausaloidGraph, IdentificationValue};

// Generates a fixed sized array with sample data
pub fn generate_sample_data<const N: usize>() -> [f64; N] {
    [0.99; N]
}

pub fn build_linear_graph(k: usize) -> CausaloidGraph<BaseCausaloid<f64, f64>> {
    let mut g = CausaloidGraph::<BaseCausaloid<f64, f64>>::new(0 as IdentificationValue);

    let root_causaloid = test_utils::get_test_causaloid_num_input_output(0);
    let root_index = g
        .add_root_causaloid(root_causaloid)
        .expect("Failed to add root causaloid");

    let mut previous_idx = root_index;

    for i in 1..k {
        let causaloid = test_utils::get_test_causaloid_num_input_output(i as IdentificationValue);
        let current_idx = g.add_causaloid(causaloid).expect("Failed to add causaloid");

        g.add_edge(previous_idx, current_idx)
            .expect("Failed to add edge");

        previous_idx = current_idx;
    }

    g.freeze();

    g
}

pub fn get_small_multi_cause_graph_and_data() -> (CausaloidGraph<BaseCausaloid<f64, f64>>, [f64; 4])
{
    let g = build_multi_cause_graph();
    (g, test_utils::generate_sample_data())
}

pub fn build_multi_cause_graph() -> CausaloidGraph<BaseCausaloid<f64, f64>> {
    // Builds a multi cause graph
    //  root(0)
    //  /  \
    //A(1) B(2)
    //  \ /
    //  C(3)

    let mut g = CausaloidGraph::<BaseCausaloid<f64, f64>>::new(0 as IdentificationValue);

    // Add root causaloid
    let root_causaloid = test_utils::get_test_causaloid_num_input_output(0);
    let root_index = g
        .add_root_causaloid(root_causaloid)
        .expect("Failed to add root causaloid");

    // Add causaloid A
    let causaloid = test_utils::get_test_causaloid_num_input_output(1);
    let idx_a = g.add_causaloid(causaloid).expect("Failed to add causaloid");

    // Link causaloid root to A causaloid
    g.add_edge(root_index, idx_a)
        .expect("Failed to add edge between root and A");

    // Add causaloid B
    let causaloid = test_utils::get_test_causaloid_num_input_output(2);
    let idx_b = g.add_causaloid(causaloid).expect("Failed to add causaloid");

    // Link causaloid B to root causaloid
    g.add_edge(root_index, idx_b)
        .expect("Failed to add edge between root and B");

    // Add causaloid C
    let causaloid = test_utils::get_test_causaloid_num_input_output(3);
    let idx_c = g.add_causaloid(causaloid).expect("Failed to add causaloid");

    // Link causaloid A to C
    g.add_edge(idx_a, idx_c)
        .expect("Failed to add edge between A and C");

    // Link causaloid B to C
    g.add_edge(idx_b, idx_c)
        .expect("Failed to add edge between C and B");

    // Now, we have a graph like this:
    //  root(0)
    //  /  \
    //A(1) B(2)
    //  \ /
    //  C(3)
    g.freeze();

    g
}

pub fn get_small_multi_layer_cause_graph_and_data()
-> (CausaloidGraph<BaseCausaloid<f64, f64>>, [f64; 8 + 1]) {
    // Builds a multi-layer cause graph:
    (build_multi_layer_cause_graph(), generate_sample_data())
}

pub fn build_multi_layer_cause_graph() -> CausaloidGraph<BaseCausaloid<f64, f64>> {
    // Builds a multi-layer cause graph:
    //    root
    //  /   |  \
    //  A   B   C
    // /\  /\  /\
    //D   E   F  G

    let mut g = CausaloidGraph::new(0);

    // Add root causaloid
    let root_causaloid = test_utils::get_test_causaloid_num_input_output(0);
    let root_index = g
        .add_root_causaloid(root_causaloid)
        .expect("Failed to add root causaloid");

    // ### First layer ### //

    // Add causaloid A
    let causaloid = test_utils::get_test_causaloid_num_input_output(1);
    let idx_a = g.add_causaloid(causaloid).expect("Failed to add causaloid");
    // Link causaloid A to root causaloid
    g.add_edge(root_index, idx_a)
        .expect("Failed to add edge between root and A");

    // Add causaloid B
    let causaloid = test_utils::get_test_causaloid_num_input_output(2);
    let idx_b = g.add_causaloid(causaloid).expect("Failed to add causaloid");
    // Link causaloid B to root causaloid
    g.add_edge(root_index, idx_b)
        .expect("Failed to add edge between root and B");

    // Add causaloid C
    let causaloid = test_utils::get_test_causaloid_num_input_output(3);
    let idx_c = g.add_causaloid(causaloid).expect("Failed to add causaloid");
    // Link causaloid C  to root causaloid
    g.add_edge(root_index, idx_c)
        .expect("Failed to add edge between root and C");

    // ### Second layer ### //

    // Add causaloid D
    let causaloid = test_utils::get_test_causaloid_num_input_output(4);
    let idx_d = g.add_causaloid(causaloid).expect("Failed to add causaloid");
    // Link causaloid D  to A
    g.add_edge(idx_a, idx_d)
        .expect("Failed to add edge between D and A");

    // Add causaloid E
    let causaloid = test_utils::get_test_causaloid_num_input_output(5);
    let idx_e = g.add_causaloid(causaloid).expect("Failed to add causaloid");
    // Link causaloid E  to A
    g.add_edge(idx_a, idx_e)
        .expect("Failed to add edge between A and E");
    // Link causaloid E  to B
    g.add_edge(idx_b, idx_e)
        .expect("Failed to add edge between B and E");

    // Add causaloid F
    let causaloid = test_utils::get_test_causaloid_num_input_output(6);
    let idx_f = g.add_causaloid(causaloid).expect("Failed to add causaloid");
    // Link causaloid F  to B
    g.add_edge(idx_b, idx_f)
        .expect("Failed to add edge between B and F");
    // Link causaloid F  to C
    g.add_edge(idx_c, idx_f)
        .expect("Failed to add edge between C and F");

    // Add causaloid G
    let causaloid = test_utils::get_test_causaloid_num_input_output(7);
    let idx_g = g.add_causaloid(causaloid).expect("Failed to add causaloid");
    // Link causaloid G  to C
    g.add_edge(idx_c, idx_g)
        .expect("Failed to add edge between A and C");

    g.freeze();

    g
}

pub fn get_left_imbalanced_cause_graph() -> (CausaloidGraph<BaseCausaloid<f64, f64>>, [f64; 6 + 1])
{
    // Builds a multi-layer cause graph:
    (build_left_imbalanced_cause_graph(), generate_sample_data())
}

pub fn build_left_imbalanced_cause_graph() -> CausaloidGraph<BaseCausaloid<f64, f64>> {
    // Builds a multi-layer cause graph:
    //    root
    //  /   |  \
    //  A   B   C
    // /\
    //D  E

    let mut g = CausaloidGraph::new(0);

    // Add root causaloid
    let root_causaloid = test_utils::get_test_causaloid_num_input_output(0);
    let root_index = g
        .add_root_causaloid(root_causaloid)
        .expect("Failed to add root causaloid");

    // ### First layer ### //

    // Add causaloid A
    let causaloid = test_utils::get_test_causaloid_num_input_output(1);
    let idx_a = g.add_causaloid(causaloid).expect("Failed to add causaloid");
    // Link causaloid A to root causaloid
    g.add_edge(root_index, idx_a)
        .expect("Failed to add edge between root and A");

    // Add causaloid B
    let causaloid = test_utils::get_test_causaloid_num_input_output(2);
    let idx_b = g.add_causaloid(causaloid).expect("Failed to add causaloid");
    // Link causaloid B to root causaloid
    g.add_edge(root_index, idx_b)
        .expect("Failed to add edge between root and B");

    // Add causaloid C
    let causaloid = test_utils::get_test_causaloid_num_input_output(3);
    let idx_c = g.add_causaloid(causaloid).expect("Failed to add causaloid");
    // Link causaloid C  to root causaloid
    g.add_edge(root_index, idx_c)
        .expect("Failed to add edge between root and C");

    // ### Second layer ### //

    // Add causaloid D
    let causaloid = test_utils::get_test_causaloid_num_input_output(4);
    let idx_d = g.add_causaloid(causaloid).expect("Failed to add causaloid");
    // Link causaloid D  to A
    g.add_edge(idx_a, idx_d)
        .expect("Failed to add edge between A and E");

    // Add causaloid E
    let causaloid = test_utils::get_test_causaloid_num_input_output(5);
    let idx_e = g.add_causaloid(causaloid).expect("Failed to add causaloid");
    // Link causaloid E  to A
    g.add_edge(idx_a, idx_e)
        .expect("Failed to add edge between A and B");

    g.freeze();

    g
}

pub fn get_right_imbalanced_cause_graph() -> (CausaloidGraph<BaseCausaloid<f64, f64>>, [f64; 6 + 1])
{
    // Builds a multi-layer cause graph:
    (build_right_imbalanced_cause_graph(), generate_sample_data())
}

pub fn build_right_imbalanced_cause_graph() -> CausaloidGraph<BaseCausaloid<f64, f64>> {
    // Builds a multi-layer cause graph:
    //    root
    //  /   |  \
    //  A   B   C
    //          /\
    //         D  E

    let mut g = CausaloidGraph::new(0);

    // Add root causaloid
    let root_causaloid = test_utils::get_test_causaloid_num_input_output(0);
    let root_index = g
        .add_root_causaloid(root_causaloid)
        .expect("Failed to add root causaloid");

    // ### First layer ### //

    // Add causaloid A
    let causaloid = test_utils::get_test_causaloid_num_input_output(1);
    let idx_a = g.add_causaloid(causaloid).expect("Failed to add causaloid");
    // Link causaloid A to root causaloid
    g.add_edge(root_index, idx_a)
        .expect("Failed to add edge between rootCause and A");

    // Add causaloid B
    let causaloid = test_utils::get_test_causaloid_num_input_output(2);
    let idx_b = g.add_causaloid(causaloid).expect("Failed to add causaloid");
    // Link causaloid B to root causaloid
    g.add_edge(root_index, idx_b)
        .expect("Failed to add edge between rootCause and B");

    // Add causaloid C
    let causaloid = test_utils::get_test_causaloid_num_input_output(3);
    let idx_c = g.add_causaloid(causaloid).expect("Failed to add causaloid");
    // Link causaloid C  to root causaloid
    g.add_edge(root_index, idx_c)
        .expect("Failed to add edge between root and C");

    // ### Second layer ### //

    // Add causaloid D
    let causaloid = test_utils::get_test_causaloid_num_input_output(4);
    let idx_d = g.add_causaloid(causaloid).expect("Failed to add causaloid");
    // Link causaloid D  to C
    g.add_edge(idx_c, idx_d)
        .expect("Failed to add edge between D to C");

    // Add causaloid E
    let causaloid = test_utils::get_test_causaloid_num_input_output(5);
    let idx_e = g.add_causaloid(causaloid).expect("Failed to add causaloid");
    // Link causaloid E  to C
    g.add_edge(idx_c, idx_e)
        .expect("Failed to add edge between c and e");

    g.freeze();

    g
}
