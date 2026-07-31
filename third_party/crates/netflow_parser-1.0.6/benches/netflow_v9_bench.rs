use criterion::{Criterion, criterion_group, criterion_main};
use netflow_parser::NetflowParser;
use std::hint::black_box;

fn criterion_benchmark(c: &mut Criterion) {
    c.bench_function("netflow_v9 bench", |b| {
        // Full packet with template flowset + data flowset
        let v9_template_packet = [
            0, 9, 0, 2, 0, 0, 9, 9, 0, 1, 2, 3, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 16, 1, 2, 0,
            2, 0, 1, 0, 4, 0, 8, 0, 4, 1, 2, 0, 12, 9, 2, 3, 4, 9, 9, 9, 8,
        ];
        // Data-only packet: V9 header (20 bytes) + data flowset (set_id=258, len=12, 8 bytes data)
        let v9_data_packet: [u8; 32] = [
            // V9 Header (count=1)
            0, 9, 0, 1, 0, 0, 9, 9, 0, 1, 2, 3, 0, 0, 0, 1, 0, 0, 0, 1,
            // Data FlowSet: set_id=258, length=12, data
            1, 2, 0, 12, 9, 2, 3, 4, 9, 9, 9, 8,
        ];
        let mut parser = NetflowParser::default();
        // Parse the full packet once to load the template into the cache
        let _ = parser.parse_bytes(&v9_template_packet);
        // Benchmark only data parsing
        b.iter(|| {
            let _ = parser.parse_bytes(black_box(&v9_data_packet));
        })
    });
}

criterion_group!(benches, criterion_benchmark);
criterion_main!(benches);
