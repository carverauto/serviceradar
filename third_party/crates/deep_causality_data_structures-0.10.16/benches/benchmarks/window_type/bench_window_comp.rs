/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use criterion::{BenchmarkId, Criterion, criterion_group};
use std::hint::black_box;

use deep_causality_data_structures::{ArrayStorage, VectorStorage, WindowStorage};

const SIZE: usize = 4;
const CAPACITY: usize = 1200;
const MULT: usize = 300; // 300 * 4 = 1200 Same capacity for Vec impl as for Array impl

fn array_operations(c: &mut Criterion) {
    let mut group = c.benchmark_group("array_operations");

    // Basic push operation
    group.bench_function("push_single", |b| {
        let mut storage = ArrayStorage::<i32, SIZE, CAPACITY>::new();
        b.iter(|| {
            storage.push(black_box(42));
        });
    });

    // Push operation with rewind
    group.bench_function("push_with_rewind", |b| {
        let mut storage = ArrayStorage::<i32, SIZE, CAPACITY>::new();
        for _ in 0..CAPACITY - 1 {
            storage.push(42);
        }
        b.iter(|| {
            storage.push(black_box(42));
        });
    });

    // Sequential operations
    group.bench_function("sequential_ops", |b| {
        let mut storage = ArrayStorage::<i32, SIZE, CAPACITY>::new();
        for i in 0..SIZE {
            storage.push(i as i32);
        }
        b.iter(|| {
            storage.push(black_box(42));
            black_box(storage.first().unwrap());
            black_box(storage.last().unwrap());
            black_box(storage.get_slice());
        });
    });

    // Batch operations
    for size in [10, 50, 100].iter() {
        group.bench_with_input(BenchmarkId::new("batch_push", size), size, |b, &size| {
            let mut storage = ArrayStorage::<i32, SIZE, CAPACITY>::new();
            b.iter(|| {
                for i in 0..size {
                    storage.push(black_box(i));
                }
            });
        });
    }

    // Memory access patterns
    group.bench_function("memory_access", |b| {
        let mut storage = ArrayStorage::<i32, SIZE, CAPACITY>::new();
        for i in 0..100 {
            storage.push(i);
        }
        b.iter(|| {
            for i in 0..10 {
                storage.push(black_box(i));
                black_box(storage.get_slice());
            }
        });
    });

    group.finish();
}
fn vector_operations(c: &mut Criterion) {
    let mut group = c.benchmark_group("vector_operations");

    // Basic push operation
    group.bench_function("push_single", |b| {
        let mut storage = VectorStorage::new(SIZE, MULT);
        b.iter(|| {
            storage.push(black_box(42));
        });
    });

    // Sequential operations
    group.bench_function("sequential_ops", |b| {
        let mut storage = VectorStorage::new(SIZE, MULT);
        for i in 0..SIZE {
            storage.push(i as i32);
        }
        b.iter(|| {
            storage.push(black_box(42));
            black_box(storage.first().unwrap());
            black_box(storage.last().unwrap());
            black_box(storage.get_slice());
        });
    });

    // Batch operations
    for size in [10, 50, 100].iter() {
        group.bench_with_input(BenchmarkId::new("batch_push", size), size, |b, &size| {
            let mut storage = VectorStorage::new(SIZE, MULT);
            b.iter(|| {
                for i in 0..size {
                    storage.push(black_box(i));
                }
            });
        });
    }

    group.finish();
}

criterion_group! {
    name = window_impl_comp;
    config = Criterion::default().sample_size(100);
    targets = array_operations, vector_operations
}
