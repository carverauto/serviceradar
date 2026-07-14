//! secp521r1 field element benchmarks

use criterion::{
    BenchmarkGroup, Criterion, criterion_group, criterion_main, measurement::Measurement,
};
use elliptic_curve::array::Array;
use hex_literal::hex;
use p521::FieldElement;
use std::hint::black_box;

fn test_field_element_x() -> FieldElement {
    black_box(FieldElement::from_bytes(
        &Array(hex!("01a7596d38aac7868327ddc1ef5e8178cf052b7ebc512828e8a45955d85bef49494d15278198bbcc5454358c12a2af9a3874e7002e1a2f02fcb36ff3e3b4bc0c69e7"))
    )
    .unwrap())
}

fn test_field_element_y() -> FieldElement {
    black_box(FieldElement::from_bytes(
        &Array(hex!("0184902e515982bb225b8c84f245e61b327c08e94d41c07d0b4101a963e02fe52f6a9f33e8b1de2394e0cb74c40790b4e489b5500e6804cabed0fe8c192443d4027b"))
    )
    .unwrap())
}

fn bench_field_element_mul<'a, M: Measurement>(group: &mut BenchmarkGroup<'a, M>) {
    let x = test_field_element_x();
    let y = test_field_element_y();
    group.bench_function("mul", |b| b.iter(|| &x * &y));
}

fn bench_field_element_square<'a, M: Measurement>(group: &mut BenchmarkGroup<'a, M>) {
    let x = test_field_element_x();
    group.bench_function("square", |b| b.iter(|| x.square()));
}

fn bench_field_element_sqrt<'a, M: Measurement>(group: &mut BenchmarkGroup<'a, M>) {
    let x = test_field_element_x();
    group.bench_function("sqrt", |b| b.iter(|| x.sqrt()));
}

fn bench_field_element_invert<'a, M: Measurement>(group: &mut BenchmarkGroup<'a, M>) {
    let x = test_field_element_x();
    group.bench_function("invert", |b| b.iter(|| x.invert()));
}

fn bench_field_element(c: &mut Criterion) {
    let mut group = c.benchmark_group("field element operations");
    bench_field_element_mul(&mut group);
    bench_field_element_square(&mut group);
    bench_field_element_invert(&mut group);
    bench_field_element_sqrt(&mut group);
    group.finish();
}

criterion_group!(benches, bench_field_element);
criterion_main!(benches);
