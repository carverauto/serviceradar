/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use criterion::criterion_main;

mod benchmarks;

// In case of SIGSEGV: invalid memory reference,
// just reduce sample size.
criterion_main! {
    benchmarks::bench_linear::liner_graph_bench_collection,
    benchmarks::bench_biconnectivity::biconnectivity_bench_collection,
}
