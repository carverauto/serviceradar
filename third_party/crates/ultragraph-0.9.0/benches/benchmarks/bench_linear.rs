/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use criterion::{BatchSize, Criterion, criterion_group};
use deep_causality_rand::{Rng, rng};
use std::hint::black_box;
// Use modern rand imports
use ultragraph::*;

use crate::benchmarks::data::Data;
use crate::benchmarks::fields::{LARGE, MEDIUM, SMALL};
use crate::benchmarks::utils;

// Type alias for convenience
type UGraph = UltraGraph<Data>;

fn get_empty_ultra_graph(capacity: usize) -> UGraph {
    UltraGraph::with_capacity(capacity, None)
}

fn get_pre_filled_ultra_graph(capacity: usize) -> UGraph {
    match capacity {
        SMALL => utils::build_linear_graph(SMALL),
        MEDIUM => utils::build_linear_graph(MEDIUM),
        LARGE => utils::build_linear_graph(LARGE),
        _ => unreachable!(),
    }
}

// Generic benchmark function for adding nodes to avoid repetition
fn bench_add_node(c: &mut Criterion, name: &str, capacity: usize) {
    let d = Data::default();

    c.bench_function(name, |b| {
        // Use iter_batched to create a new graph for each measurement
        b.iter_batched(
            || get_empty_ultra_graph(capacity), // SETUP: Create a fresh, empty graph
            |mut g| g.add_node(d),              // ROUTINE: The operation to benchmark
            BatchSize::LargeInput,              // A hint for criterion about the workload
        );
    });
}

// Generic benchmark function for getting nodes to avoid repetition
fn bench_get_node(c: &mut Criterion, name: &str, capacity: usize) {
    let g = get_pre_filled_ultra_graph(capacity);
    let mut rng = rng(); // Create RNG once

    c.bench_function(name, |b| {
        b.iter(|| {
            let index = rng.random_range(0..capacity);
            black_box(g.get_node(index))
        })
    });
}

fn linear_graph_benchmarks(c: &mut Criterion) {
    // Benchmarks for adding nodes
    bench_add_node(c, "small_add_node", SMALL);
    bench_add_node(c, "medium_add_node", MEDIUM);
    bench_add_node(c, "large_add_node", LARGE);

    // Benchmarks for getting nodes
    bench_get_node(c, "small_get_node", SMALL);
    bench_get_node(c, "medium_get_node", MEDIUM);
    bench_get_node(c, "large_get_node", LARGE);
}

criterion_group! {
    name = liner_graph_bench_collection;
    config = Criterion::default().sample_size(100);
    targets = linear_graph_benchmarks
}
