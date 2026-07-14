use criterion::{Criterion, criterion_group, criterion_main};
use flowparser_sflow::SflowParser;

fn bench_parse_counter_sample(c: &mut Criterion) {
    // sFlow v5 datagram with 1 counter sample containing 1 VLAN counter
    #[rustfmt::skip]
    let data: Vec<u8> = vec![
        0, 0, 0, 5,    // version 5
        0, 0, 0, 1,    // address type IPv4
        10, 0, 0, 1,   // agent address
        0, 0, 0, 0,    // sub_agent_id
        0, 0, 0, 1,    // sequence_number
        0, 0, 0, 100,  // uptime
        0, 0, 0, 1,    // num_samples = 1
        // Sample: enterprise=0, format=2 (counter sample)
        0, 0, 0, 2,    // data_format
        0, 0, 0, 36,   // sample_length
        // Counter sample header
        0, 0, 0, 1,    // sequence_number
        0, 0, 0, 1,    // source_id
        0, 0, 0, 1,    // num_records = 1
        // Counter record: enterprise=0, format=5 (VLAN)
        0, 0, 0, 5,    // data_format
        0, 0, 0, 28,   // record_length (28 bytes)
        0, 0, 0, 100,  // vlan_id
        0, 0, 0, 0, 0, 0, 0x10, 0, // octets
        0, 0, 0, 50,   // ucast_pkts
        0, 0, 0, 5,    // multicast_pkts
        0, 0, 0, 2,    // broadcast_pkts
        0, 0, 0, 0,    // discards
    ];

    let parser = SflowParser::default();
    c.bench_function("parse_counter_sample", |b| {
        b.iter(|| parser.parse_bytes(&data))
    });
}

criterion_group!(benches, bench_parse_counter_sample);
criterion_main!(benches);
