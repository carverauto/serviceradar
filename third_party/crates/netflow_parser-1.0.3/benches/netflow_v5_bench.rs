use criterion::{Criterion, criterion_group, criterion_main};
use netflow_parser::NetflowParser;
use std::hint::black_box;

fn criterion_benchmark(c: &mut Criterion) {
    c.bench_function("netflow_v5 bench", |b| {
        let v5_packet = [
            0, 5, 0, 1, 3, 0, 4, 0, 5, 0, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3,
            4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1,
            2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7,
        ];
        let mut parser = NetflowParser::default();
        b.iter(|| {
            let _ = parser.parse_bytes(black_box(&v5_packet));
        })
    });
}

criterion_group!(benches, criterion_benchmark);
criterion_main!(benches);
