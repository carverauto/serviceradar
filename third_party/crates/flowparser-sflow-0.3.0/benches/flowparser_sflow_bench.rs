use criterion::{Criterion, criterion_group, criterion_main};
use flowparser_sflow::SflowParser;

fn bench_parse_datagram(c: &mut Criterion) {
    // Minimal sFlow v5 datagram: IPv4 agent, 0 samples
    let data: Vec<u8> = vec![
        0, 0, 0, 5, // version 5
        0, 0, 0, 1, // address type IPv4
        10, 0, 0, 1, // agent address
        0, 0, 0, 0, // sub_agent_id
        0, 0, 0, 1, // sequence_number
        0, 0, 0, 100, // uptime
        0, 0, 0, 0, // num_samples = 0
    ];

    let parser = SflowParser::default();
    c.bench_function("parse_empty_datagram", |b| {
        b.iter(|| parser.parse_bytes(&data))
    });
}

criterion_group!(benches, bench_parse_datagram);
criterion_main!(benches);
