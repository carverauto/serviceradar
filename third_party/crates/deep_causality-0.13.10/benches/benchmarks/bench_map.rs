/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use criterion::{Criterion, criterion_group};
use deep_causality::utils_test::test_utils_map;
use deep_causality::{MonadicCausable, PropagatingEffect};
use deep_causality_core::EffectValue;
// Small = 10
// Medium = 1_000
// Large = 10_000

fn small_causality_map_benchmark(criterion: &mut Criterion) {
    let (map, data) = test_utils_map::get_small_map_and_data();

    criterion.bench_function("small_causality_map_independent_eval", |bencher| {
        bencher.iter(|| {
            for (key, causaloid) in &map {
                let value = data.get(key).expect("Data missing for key");
                let evidence = PropagatingEffect::from_effect_value(EffectValue::Value(*value));
                causaloid.evaluate(&evidence);
            }
        })
    });
}

fn medium_causality_map_benchmark(criterion: &mut Criterion) {
    let (map, data) = test_utils_map::get_medium_map_and_data();

    criterion.bench_function("medium_causality_map_independent_eval", |bencher| {
        bencher.iter(|| {
            for (key, causaloid) in &map {
                let value = data.get(key).expect("Data missing for key");
                let evidence = PropagatingEffect::from_effect_value(EffectValue::Value(*value));
                causaloid.evaluate(&evidence);
            }
        })
    });
}

fn large_causality_map_benchmark(criterion: &mut Criterion) {
    let (map, data) = test_utils_map::get_large_map_and_data();

    criterion.bench_function("large_causality_map_independent_eval", |bencher| {
        bencher.iter(|| {
            for (key, causaloid) in &map {
                let value = data.get(key).expect("Data missing for key");
                let evidence = PropagatingEffect::from_effect_value(EffectValue::Value(*value));
                causaloid.evaluate(&evidence);
            }
        })
    });
}

criterion_group! {
    name = causality_map;
    config = Criterion::default().sample_size(100);
    targets =
    small_causality_map_benchmark,
    medium_causality_map_benchmark,
    large_causality_map_benchmark,
}
