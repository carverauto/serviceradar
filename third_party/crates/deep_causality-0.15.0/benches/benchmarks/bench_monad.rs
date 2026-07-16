/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use criterion::{Criterion, criterion_group};
use std::hint::black_box;

use deep_causality::PropagatingEffect;
use deep_causality::utils_test::test_utils_monad::*;
use deep_causality_core::AlternatableValue;

fn bench_monad_pure(criterion: &mut Criterion) {
    criterion.bench_function("monad_pure_boolean", |bencher| {
        bencher.iter(|| black_box(PropagatingEffect::pure(true)))
    });

    criterion.bench_function("monad_pure_numerical", |bencher| {
        bencher.iter(|| black_box(PropagatingEffect::pure(0.5)))
    });
}

fn bench_monad_bind_success(criterion: &mut Criterion) {
    let initial_effect = PropagatingEffect::pure(0.7);
    criterion.bench_function("monad_bind_success_two_steps", |bencher| {
        bencher.iter(|| {
            let effect = black_box(initial_effect.clone());
            effect.bind(smoking_logic).bind(tar_logic)
        })
    });
}

fn bench_monad_bind_error_propagation(criterion: &mut Criterion) {
    let initial_effect = PropagatingEffect::pure(true); // Triggers error
    criterion.bench_function("monad_bind_error_propagation", |bencher| {
        bencher.iter(|| {
            let effect = black_box(initial_effect.clone());
            effect.bind(error_logic).bind(tar_logic)
        })
    });
}

fn bench_monad_alternate_value(criterion: &mut Criterion) {
    let initial_effect = PropagatingEffect::pure(0.9);
    criterion.bench_function("monad_alternate_value_replacement", |bencher| {
        bencher.iter(|| {
            let effect = black_box(initial_effect.clone());
            effect.alternate_value(0.1) // alternate_value takes T, not CausalEffect<T>
        })
    });
}

fn bench_monad_chain_with_alternate_value(criterion: &mut Criterion) {
    let initial_effect = PropagatingEffect::pure(0.9);
    criterion.bench_function("monad_chain_with_alternate_value", |bencher| {
        bencher.iter(|| {
            let effect = black_box(initial_effect.clone());
            effect
                .bind(smoking_logic)
                .alternate_value(false)
                .bind(tar_logic)
        })
    });
}

criterion_group! {
    name = monad_benches;
    config = Criterion::default().sample_size(100);
    targets =
        bench_monad_pure,
        bench_monad_bind_success,
        bench_monad_bind_error_propagation,
        bench_monad_alternate_value,
        bench_monad_chain_with_alternate_value,
}
