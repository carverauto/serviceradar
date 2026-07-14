//! secp521r1 scalar arithmetic benchmarks

use criterion::{
    BenchmarkGroup, Criterion, criterion_group, criterion_main, measurement::Measurement,
};
use hex_literal::hex;
use p521::{ProjectivePoint, Scalar, elliptic_curve::group::ff::PrimeField};
use std::hint::black_box;

fn test_scalar_x() -> Scalar {
    black_box(Scalar::from_repr(
        hex!("01d7bb864c5b5ecae019296cf9b5c63a166f5f1113942819b1933d889a96d12245777a99428f93de4fc9a18d709bf91889d7f8dddd522b4c364aeae13c983e9fae46").into()
    ).unwrap())
}

fn test_scalar_y() -> Scalar {
    black_box(Scalar::from_repr(
        hex!("017e49b8ea8f9d1b7c0378e378a7a42e68e12cf78779ed41dcd29a090ae7e0f883b0d0f2cbc8f0473c0ad6732bea40d371a7f363bc6537d075bd1a4c23e558b0bc73").into()
    ).unwrap())
}

fn bench_point_mul<M: Measurement>(group: &mut BenchmarkGroup<'_, M>) {
    let p = ProjectivePoint::GENERATOR;
    let m = test_scalar_x();
    let s = Scalar::from_repr(m.into()).unwrap();
    group.bench_function("point-scalar mul", |b| b.iter(|| p * s));
}

fn bench_scalar_sub<M: Measurement>(group: &mut BenchmarkGroup<'_, M>) {
    let x = test_scalar_x();
    let y = test_scalar_y();
    group.bench_function("sub", |b| b.iter(|| x - y));
}

fn bench_scalar_add<M: Measurement>(group: &mut BenchmarkGroup<'_, M>) {
    let x = test_scalar_x();
    let y = test_scalar_y();
    group.bench_function("add", |b| b.iter(|| x + y));
}

fn bench_scalar_mul<M: Measurement>(group: &mut BenchmarkGroup<'_, M>) {
    let x = test_scalar_x();
    let y = test_scalar_y();
    group.bench_function("mul", |b| b.iter(|| x * y));
}

fn bench_scalar_negate<M: Measurement>(group: &mut BenchmarkGroup<'_, M>) {
    let x = test_scalar_x();
    group.bench_function("negate", |b| b.iter(|| -x));
}

fn bench_scalar_invert<M: Measurement>(group: &mut BenchmarkGroup<'_, M>) {
    let x = test_scalar_x();
    group.bench_function("invert", |b| b.iter(|| x.invert()));
}

fn bench_point(c: &mut Criterion) {
    let mut group = c.benchmark_group("point operations");
    bench_point_mul(&mut group);
    group.finish();
}

fn bench_scalar(c: &mut Criterion) {
    let mut group = c.benchmark_group("scalar operations");
    bench_scalar_sub(&mut group);
    bench_scalar_add(&mut group);
    bench_scalar_mul(&mut group);
    bench_scalar_negate(&mut group);
    bench_scalar_invert(&mut group);
    group.finish();
}

criterion_group!(benches, bench_point, bench_scalar);
criterion_main!(benches);
