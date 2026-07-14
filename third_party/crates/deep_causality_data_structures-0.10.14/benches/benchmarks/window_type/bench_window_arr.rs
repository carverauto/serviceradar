/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use criterion::{Criterion, criterion_group};

use deep_causality_data_structures::{ArrayStorage, SlidingWindow, window_type};

use crate::benchmarks::fields::{MULT, SIZE};

#[derive(Default, Debug, Copy, Clone, Hash, Eq, PartialEq)]
pub struct Data {
    dats: i32,
}

fn get_sliding_window() -> SlidingWindow<ArrayStorage<Data, SIZE, MULT>, Data> {
    window_type::new_with_array_storage()
}

fn array_backed_benchmark(criterion: &mut Criterion) {
    let mut w = get_sliding_window();
    criterion.bench_function("array_push", |bencher| {
        bencher.iter(|| w.push(Data { dats: 0 }))
    });
}

criterion_group! {
    name = window_array_backed;
    config = Criterion::default().sample_size(100);
    targets =
    array_backed_benchmark,
}
