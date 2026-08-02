/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use criterion::criterion_main;

mod benchmarks;

criterion_main! {
    benchmarks::causal_tensor_type::bench_causal_tensor::causal_tensor_benches,
    benchmarks::causal_tensor_network_type::bench_svd_qr::svd_qr_benches,
    benchmarks::causal_tensor_network_type::bench_tensor_train_core::tensor_train_core_benches,
    benchmarks::causal_tensor_network_type::bench_tensor_train_operator::tensor_train_operator_benches,
    benchmarks::causal_tensor_network_type::bench_tensor_train_cross::tensor_train_cross_benches,
    benchmarks::causal_tensor_network_type::bench_tensor_train_solve::tensor_train_solve_benches,
}
