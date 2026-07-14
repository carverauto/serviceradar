/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use criterion::{Criterion, criterion_group};
use std::hint::black_box;

use deep_causality::utils_test::test_utils_graph;
use deep_causality::*;

const SMALL: usize = 10;
const MEDIUM: usize = 1_000;
const LARGE: usize = 10_000;

fn small_linear_graph_benchmark(criterion: &mut Criterion) {
    let g = test_utils_graph::build_linear_graph(SMALL);
    let evidence = PropagatingEffect::from_effect_value(EffectValue::Value(0.99));
    let root_index = g.get_root_index().unwrap();

    criterion.bench_function(
        "small_linear_graph_evaluate_subgraph_from_root",
        |bencher| bencher.iter(|| g.evaluate_subgraph_from_cause(root_index, &evidence)),
    );

    let start_index = g.number_nodes() / 2;
    let stop_index = g.number_nodes() - 1;

    criterion.bench_function("small_linear_graph_evaluate_shortest_path", |bencher| {
        bencher.iter(|| g.evaluate_shortest_path_between_causes(start_index, stop_index, &evidence))
    });

    let single_cause_index = g.number_nodes() / 2;
    criterion.bench_function("small_linear_graph_evaluate_single_cause", |bencher| {
        bencher.iter(|| {
            // Also black_box the result to ensure this code is never considered "dead" or unused.
            black_box(g.evaluate_single_cause(single_cause_index, &evidence));
        })
    });
}

fn medium_linear_graph_benchmark(criterion: &mut Criterion) {
    let g = test_utils_graph::build_linear_graph(MEDIUM);
    let evidence = PropagatingEffect::from_effect_value(EffectValue::Value(0.99));
    let root_index = g.get_root_index().unwrap();

    criterion.bench_function(
        "medium_linear_graph_evaluate_subgraph_from_root",
        |bencher| bencher.iter(|| g.evaluate_subgraph_from_cause(root_index, &evidence)),
    );

    let start_index = g.number_nodes() / 2;
    let stop_index = g.number_nodes() - 1;

    criterion.bench_function("medium_linear_graph_evaluate_shortest_path", |bencher| {
        bencher.iter(|| g.evaluate_shortest_path_between_causes(start_index, stop_index, &evidence))
    });

    let single_cause_index = g.number_nodes() / 2;
    criterion.bench_function("medium_linear_graph_evaluate_single_cause", |bencher| {
        bencher.iter(|| {
            // Also black_box the result to ensure this code is never considered "dead" or unused.
            black_box(g.evaluate_single_cause(single_cause_index, &evidence));
        })
    });
}

fn large_linear_graph_benchmark(criterion: &mut Criterion) {
    let g = test_utils_graph::build_linear_graph(LARGE);
    let evidence = PropagatingEffect::from_effect_value(EffectValue::Value(0.99));
    let root_index = g.get_root_index().unwrap();

    criterion.bench_function(
        "large_linear_graph_evaluate_subgraph_from_root",
        |bencher| bencher.iter(|| g.evaluate_subgraph_from_cause(root_index, &evidence)),
    );

    let start_index = g.number_nodes() / 2;
    let stop_index = g.number_nodes() - 1;

    criterion.bench_function("large_linear_graph_evaluate_shortest_path", |bencher| {
        bencher.iter(|| g.evaluate_shortest_path_between_causes(start_index, stop_index, &evidence))
    });

    let single_cause_index = g.number_nodes() / 2;
    criterion.bench_function("large_linear_graph_evaluate_single_cause", |bencher| {
        bencher.iter(|| {
            // Also black_box the result to ensure this code is never considered "dead" or unused.
            black_box(g.evaluate_single_cause(single_cause_index, &evidence));
        })
    });
}

criterion_group! {
    name = linear_graph;
    config = Criterion::default().sample_size(100);
    targets =
    small_linear_graph_benchmark,
    medium_linear_graph_benchmark,
    large_linear_graph_benchmark,
}
