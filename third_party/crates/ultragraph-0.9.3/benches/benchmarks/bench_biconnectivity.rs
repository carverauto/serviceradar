/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Benchmarks for the biconnectivity decomposition trio
//! (`articulation_points`, `bridges`, `biconnected_components`).
//!
//! Fixture: a chain of `k` triangles sharing consecutive vertices
//! (triangles `{0,1,2}`, `{2,3,4}`, `{4,5,6}`, ...). For `k` triangles:
//!   V = 2k + 1, E = 3k
//!   articulation_points = k - 1 (the shared vertices)
//!   bridges             = 0
//!   biconnected_components = k
//!
//! This shape exercises every branch of each algorithm (tree edges,
//! back edges, articulation-condition firing, edge-stack popping).

use criterion::{Criterion, criterion_group};
use std::hint::black_box;
use ultragraph::*;

use crate::benchmarks::data::Data;
use crate::benchmarks::fields::{LARGE, MEDIUM, SMALL};

/// 10K vertices, ~15K edges — matches the ServiceRadar-scale target
/// called out in the spec's complexity-guarantee scenario.
const XLARGE_TRIANGLES: usize = 5_000;

fn build_triangle_chain(num_triangles: usize) -> UltraGraph<Data> {
    let v = 2 * num_triangles + 1;
    let mut g: UltraGraphContainer<Data, _> = UltraGraph::with_capacity(v, None);
    for _ in 0..v {
        g.add_node(Data::default()).unwrap();
    }
    for k in 0..num_triangles {
        let a = 2 * k;
        let b = 2 * k + 1;
        let c = 2 * k + 2;
        g.add_edge(a, b, ()).unwrap();
        g.add_edge(b, c, ()).unwrap();
        g.add_edge(c, a, ()).unwrap();
    }
    g.freeze();
    g
}

fn bench_articulation(c: &mut Criterion, name: &str, num_triangles: usize) {
    let g = build_triangle_chain(num_triangles);
    c.bench_function(name, |b| {
        b.iter(|| {
            let r = g.articulation_points().unwrap();
            black_box(r);
        })
    });
}

fn bench_bridges(c: &mut Criterion, name: &str, num_triangles: usize) {
    let g = build_triangle_chain(num_triangles);
    c.bench_function(name, |b| {
        b.iter(|| {
            let r = g.bridges().unwrap();
            black_box(r);
        })
    });
}

fn bench_biconnected(c: &mut Criterion, name: &str, num_triangles: usize) {
    let g = build_triangle_chain(num_triangles);
    c.bench_function(name, |b| {
        b.iter(|| {
            let r = g.biconnected_components().unwrap();
            black_box(r);
        })
    });
}

fn biconnectivity_benchmarks(c: &mut Criterion) {
    bench_articulation(c, "small_articulation_points", SMALL);
    bench_articulation(c, "medium_articulation_points", MEDIUM);
    bench_articulation(c, "large_articulation_points", LARGE);
    bench_articulation(
        c,
        "xlarge_articulation_points_5k_triangles",
        XLARGE_TRIANGLES,
    );

    bench_bridges(c, "small_bridges", SMALL);
    bench_bridges(c, "medium_bridges", MEDIUM);
    bench_bridges(c, "large_bridges", LARGE);
    bench_bridges(c, "xlarge_bridges_5k_triangles", XLARGE_TRIANGLES);

    bench_biconnected(c, "small_biconnected_components", SMALL);
    bench_biconnected(c, "medium_biconnected_components", MEDIUM);
    bench_biconnected(c, "large_biconnected_components", LARGE);
    bench_biconnected(
        c,
        "xlarge_biconnected_components_5k_triangles",
        XLARGE_TRIANGLES,
    );
}

criterion_group! {
    name = biconnectivity_bench_collection;
    config = Criterion::default().sample_size(20);
    targets = biconnectivity_benchmarks
}
