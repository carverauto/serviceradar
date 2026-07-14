/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use criterion::{Criterion, criterion_group};
use deep_causality::utils_test::test_utils_collection;
use deep_causality::*;

// Small = 10
// Medium = 1_000
// Large = 10_000

fn small_causality_collection_benchmark(criterion: &mut Criterion) {
    let (coll, _data) = test_utils_collection::get_small_collection_and_data();
    let evidence = PropagatingEffect::from_effect_value(EffectValue::Value(0.99));

    criterion.bench_function("small_causality_collection_propagation", |bencher| {
        bencher.iter(|| coll.evaluate_collection(&evidence, &AggregateLogic::All, None))
    });
}

fn medium_causality_collection_benchmark(criterion: &mut Criterion) {
    let (coll, _data) = test_utils_collection::get_medium_collection_and_data();
    let evidence = PropagatingEffect::from_effect_value(EffectValue::Value(0.99));

    criterion.bench_function("medium_causality_collection_propagation", |bencher| {
        bencher.iter(|| coll.evaluate_collection(&evidence, &AggregateLogic::All, None))
    });
}

fn large_causality_collection_benchmark(criterion: &mut Criterion) {
    let (coll, _data) = test_utils_collection::get_large_collection_and_data();
    let evidence = PropagatingEffect::from_effect_value(EffectValue::Value(0.99));

    criterion.bench_function("large_causality_collection_propagation", |bencher| {
        bencher.iter(|| coll.evaluate_collection(&evidence, &AggregateLogic::All, None))
    });
}

criterion_group! {
    name = causality_collection;
    config = Criterion::default().sample_size(100);
    targets =
    small_causality_collection_benchmark,
    medium_causality_collection_benchmark,
    large_causality_collection_benchmark,
}
