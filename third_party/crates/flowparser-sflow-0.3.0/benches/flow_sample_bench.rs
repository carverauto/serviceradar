use criterion::{Criterion, criterion_group, criterion_main};
use flowparser_sflow::SflowParser;

fn bench_parse_flow_sample(c: &mut Criterion) {
    // sFlow v5 datagram with 1 flow sample containing 1 extended switch record
    #[rustfmt::skip]
    let data: Vec<u8> = vec![
        0, 0, 0, 5,    // version 5
        0, 0, 0, 1,    // address type IPv4
        10, 0, 0, 1,   // agent address
        0, 0, 0, 0,    // sub_agent_id
        0, 0, 0, 1,    // sequence_number
        0, 0, 0, 100,  // uptime
        0, 0, 0, 1,    // num_samples = 1
        // Sample: enterprise=0, format=1 (flow sample)
        0, 0, 0, 1,    // data_format
        0, 0, 0, 52,   // sample_length (52 bytes)
        // Flow sample header
        0, 0, 0, 1,    // sequence_number
        0, 0, 0, 3,    // source_id
        0, 0, 1, 0,    // sampling_rate
        0, 0, 0, 100,  // sample_pool
        0, 0, 0, 0,    // drops
        0, 0, 0, 1,    // input
        0, 0, 0, 2,    // output
        0, 0, 0, 1,    // num_records = 1
        // Flow record: enterprise=0, format=1001 (extended switch)
        0, 0, 3, 233,  // data_format (0 << 12 | 1001)
        0, 0, 0, 16,   // record_length
        0, 0, 0, 100,  // src_vlan
        0, 0, 0, 0,    // src_priority
        0, 0, 0, 200,  // dst_vlan
        0, 0, 0, 0,    // dst_priority
    ];

    let parser = SflowParser::default();
    c.bench_function("parse_flow_sample", |b| {
        b.iter(|| parser.parse_bytes(&data))
    });
}

criterion_group!(benches, bench_parse_flow_sample);
criterion_main!(benches);
