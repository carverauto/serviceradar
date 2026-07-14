use criterion::{Criterion, criterion_group, criterion_main};
use netflow_parser::NetflowParser;
use std::hint::black_box;

fn criterion_benchmark(c: &mut Criterion) {
    c.bench_function("netflow_ipfix bench", |b| {
        // Full packet with template set + data set
        let ipfix_template_packet = [
            0, 10, 0, 64, 1, 2, 3, 4, 0, 0, 0, 0, 1, 2, 3, 4, 0, 2, 0, 20, 1, 0, 0, 3, 0, 8, 0,
            4, 0, 12, 0, 4, 0, 2, 0, 4, 1, 0, 0, 28, 1, 2, 3, 4, 1, 2, 3, 3, 1, 2, 3, 2, 0, 2,
            0, 2, 0, 1, 2, 3, 4, 5, 6, 7,
        ];
        // Data-only packet: IPFIX header (16 bytes, length=44) + data set (set_id=256, len=28, 24 bytes data)
        let ipfix_data_packet: [u8; 44] = [
            // IPFIX Header (version=10, length=44)
            0, 10, 0, 44, 1, 2, 3, 4, 0, 0, 0, 0, 1, 2, 3, 4,
            // Data Set: set_id=256, length=28, data
            1, 0, 0, 28, 1, 2, 3, 4, 1, 2, 3, 3, 1, 2, 3, 2, 0, 2, 0, 2, 0, 1, 2, 3, 4, 5, 6, 7,
        ];
        let mut parser = NetflowParser::default();
        // Parse the full packet once to load the template into the cache
        let _ = parser.parse_bytes(&ipfix_template_packet);
        // Benchmark only data parsing
        b.iter(|| {
            let _ = parser.parse_bytes(black_box(&ipfix_data_packet));
        })
    });
}

criterion_group!(benches, criterion_benchmark);
criterion_main!(benches);
