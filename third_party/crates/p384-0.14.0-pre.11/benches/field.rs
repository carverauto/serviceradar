//! secp384r1 field element benchmarks

use criterion::{
    BenchmarkGroup, Criterion, criterion_group, criterion_main, measurement::Measurement,
};
use hex_literal::hex;
use p384::FieldElement;

fn test_field_element_x() -> FieldElement {
    FieldElement::from_bytes(
        &hex!("c2b47944fb5de342d03285880177ca5f7d0f2fcad7678cce4229d6e1932fcac11bfc3c3e97d942a3c56bf34123013dbf").into()
    )
    .unwrap()
}

fn test_field_element_y() -> FieldElement {
    FieldElement::from_bytes(
        &hex!("37257906a8223866eda0743c519616a76a758ae58aee81c5fd35fbf3a855b7754a36d4a0672df95d6c44a81cf7620c2d").into()
    )
    .unwrap()
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
