/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use criterion::{Criterion, criterion_group, criterion_main};
use deep_causality_rand::Rng;
use deep_causality_sparse::CsrMatrix;

// Helper to generate a random sparse matrix
fn generate_random_sparse_matrix(
    rows: usize,
    cols: usize,
    density: f64,
    rng: &mut impl Rng,
) -> CsrMatrix<f64> {
    let num_elements = (rows * cols) as f64 * density;
    let mut triplets = Vec::with_capacity(num_elements as usize);

    for r in 0..rows {
        for c in 0..cols {
            if rng.random_range(0.0..1.0) < density {
                let value: f64 = rng.random_range(-10.0..10.0);
                if value.abs() > f64::EPSILON {
                    triplets.push((r, c, value));
                }
            }
        }
    }
    CsrMatrix::from_triplets(rows, cols, &triplets).unwrap()
}

// --- Benchmarks for CsrMatrix Operations ---

fn bench_from_triplets(c: &mut Criterion) {
    let mut group = c.benchmark_group("CsrMatrix::from_triplets");
    let mut rng = deep_causality_rand::rng();

    for size in [100, 500, 1000].iter() {
        for density in [0.01, 0.05, 0.1].iter() {
            let num_elements = (*size * *size) as f64 * *density;
            let mut triplets_data = Vec::with_capacity(num_elements as usize);
            for r in 0..*size {
                for c in 0..*size {
                    if rng.random_range(0.0..1.0) < *density {
                        let value: f64 = rng.random_range(-10.0..10.0);
                        if value.abs() > f64::EPSILON {
                            triplets_data.push((r, c, value));
                        }
                    }
                }
            }
            // Clone triplets for each benchmark run
            let cloned_triplets = triplets_data.clone();
            group.bench_with_input(
                format!("{}x{} with density {}", size, size, density),
                &(*size, *size, cloned_triplets),
                |b, (rows, cols, trplts)| {
                    b.iter(|| CsrMatrix::from_triplets(*rows, *cols, trplts).unwrap());
                },
            );
        }
    }
    group.finish();
}

fn bench_get_value_at(c: &mut Criterion) {
    let mut group = c.benchmark_group("CsrMatrix::get_value_at");
    let mut rng = deep_causality_rand::rng();

    for size in [100, 500, 1000].iter() {
        for density in [0.01, 0.05].iter() {
            let matrix = generate_random_sparse_matrix(*size, *size, *density, &mut rng);
            let target_row = rng.random_range(0..*size);
            let target_col = rng.random_range(0..*size);

            group.bench_with_input(
                format!(
                    "{}x{} density {} at ({}, {})",
                    size, size, density, target_row, target_col
                ),
                &matrix,
                |b, mat| {
                    b.iter(|| mat.get_value_at(target_row, target_col));
                },
            );
        }
    }
    group.finish();
}

fn bench_add_matrix(c: &mut Criterion) {
    let mut group = c.benchmark_group("CsrMatrix::add_matrix");
    let mut rng = deep_causality_rand::rng();

    for size in [100, 500].iter() {
        for density in [0.01, 0.05].iter() {
            let m1 = generate_random_sparse_matrix(*size, *size, *density, &mut rng);
            let m2 = generate_random_sparse_matrix(*size, *size, *density, &mut rng);

            group.bench_with_input(
                format!("{}x{} density {}", size, size, density),
                &(&m1, &m2),
                |b, (mat1, mat2)| {
                    b.iter(|| mat1.add_matrix(mat2).unwrap());
                },
            );
        }
    }
    group.finish();
}

fn bench_sub_matrix(c: &mut Criterion) {
    let mut group = c.benchmark_group("CsrMatrix::sub_matrix");
    let mut rng = deep_causality_rand::rng();

    for size in [100, 500].iter() {
        for density in [0.01, 0.05].iter() {
            let m1 = generate_random_sparse_matrix(*size, *size, *density, &mut rng);
            let m2 = generate_random_sparse_matrix(*size, *size, *density, &mut rng);

            group.bench_with_input(
                format!("{}x{} density {}", size, size, density),
                &(&m1, &m2),
                |b, (mat1, mat2)| {
                    b.iter(|| mat1.sub_matrix(mat2).unwrap());
                },
            );
        }
    }
    group.finish();
}

fn bench_scalar_mult(c: &mut Criterion) {
    let mut group = c.benchmark_group("CsrMatrix::scalar_mult");
    let mut rng = deep_causality_rand::rng();
    let scalar = 2.0;

    for size in [100, 500, 1000].iter() {
        for density in [0.01, 0.05, 0.1].iter() {
            let matrix = generate_random_sparse_matrix(*size, *size, *density, &mut rng);

            group.bench_with_input(
                format!("{}x{} density {}", size, size, density),
                &matrix,
                |b, mat| {
                    b.iter(|| mat.scalar_mult(scalar));
                },
            );
        }
    }
    group.finish();
}

fn bench_vec_mult(c: &mut Criterion) {
    let mut group = c.benchmark_group("CsrMatrix::vec_mult");
    let mut rng = deep_causality_rand::rng();

    for size in [100, 500, 1000].iter() {
        for density in [0.01, 0.05].iter() {
            let matrix = generate_random_sparse_matrix(*size, *size, *density, &mut rng);
            let vector: Vec<f64> = (0..*size)
                .map(|_| {
                    let val: f64 = rng.random_range(-10.0..10.0);
                    val
                })
                .collect();

            group.bench_with_input(
                format!("{}x{} density {}", size, size, density),
                &(&matrix, &vector),
                |b, (mat, vec_ref)| {
                    b.iter(|| mat.vec_mult(vec_ref).unwrap());
                },
            );
        }
    }
    group.finish();
}

fn bench_mat_mult(c: &mut Criterion) {
    let mut group = c.benchmark_group("CsrMatrix::mat_mult");
    let mut rng = deep_causality_rand::rng();

    for size in [50, 100, 200].iter() {
        // Smaller sizes for mat_mult due to complexity
        for density in [0.01, 0.02].iter() {
            // Lower densities
            let m1 = generate_random_sparse_matrix(*size, *size, *density, &mut rng);
            let m2 = generate_random_sparse_matrix(*size, *size, *density, &mut rng);

            group.bench_with_input(
                format!("{}x{} density {}", size, size, density),
                &(&m1, &m2),
                |b, (mat1, mat2)| {
                    b.iter(|| mat1.mat_mult(mat2).unwrap());
                },
            );
        }
    }
    group.finish();
}

fn bench_transpose(c: &mut Criterion) {
    let mut group = c.benchmark_group("CsrMatrix::transpose");
    let mut rng = deep_causality_rand::rng();

    for size in [100, 500, 1000].iter() {
        for density in [0.01, 0.05].iter() {
            let matrix = generate_random_sparse_matrix(*size, *size, *density, &mut rng);

            group.bench_with_input(
                format!("{}x{} density {}", size, size, density),
                &matrix,
                |b, mat| {
                    b.iter(|| mat.transpose());
                },
            );
        }
    }
    group.finish();
}

criterion_group!(
    benches,
    bench_from_triplets,
    bench_get_value_at,
    bench_add_matrix,
    bench_sub_matrix,
    bench_scalar_mult,
    bench_vec_mult,
    bench_mat_mult,
    bench_transpose
);
criterion_main!(benches);
