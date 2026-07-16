/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use criterion::criterion_main;

mod benchmarks;

criterion_main! {
    benchmarks::bench_collection::causality_collection,
    benchmarks::bench_map::causality_map,
    benchmarks::bench_monad::monad_benches,
    benchmarks::bench_graph::linear_graph,
    benchmarks::bench_multi_cause_graph::multi_layer_graph,
}
