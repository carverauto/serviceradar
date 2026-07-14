use criterion::{BenchmarkId, Criterion, Throughput, criterion_group, criterion_main};
use flowparser_sflow::SflowParser;

/// Build a realistic sFlow v5 datagram with multiple flow samples,
/// each containing several record types (raw packet header, extended switch,
/// extended router, extended gateway).
fn build_realistic_datagram() -> Vec<u8> {
    let mut data = Vec::new();

    // Datagram header
    data.extend_from_slice(&0u32.to_be_bytes()); // placeholder for later
    data.extend_from_slice(&5u32.to_be_bytes()); // version 5
    data.extend_from_slice(&1u32.to_be_bytes()); // IPv4
    data.extend_from_slice(&[10, 0, 0, 1]); // agent
    data.extend_from_slice(&0u32.to_be_bytes()); // sub_agent_id
    data.extend_from_slice(&42u32.to_be_bytes()); // sequence
    data.extend_from_slice(&1000u32.to_be_bytes()); // uptime

    // We'll add 8 flow samples
    let num_samples: u32 = 8;
    data.extend_from_slice(&num_samples.to_be_bytes());

    for seq in 0..num_samples {
        let sample = build_flow_sample(seq + 1);
        // enterprise=0, format=1
        data.extend_from_slice(&1u32.to_be_bytes());
        data.extend_from_slice(&(sample.len() as u32).to_be_bytes());
        data.extend(sample);
    }

    // Fix: remove the placeholder we accidentally added
    // Actually, rebuild properly from the version field
    data[0..4].copy_from_slice(&5u32.to_be_bytes());
    // The datagram starts at version, so shift everything
    let proper = data[4..].to_vec();
    let mut result = Vec::new();
    result.extend_from_slice(&5u32.to_be_bytes()); // version
    result.extend_from_slice(&proper[4..]); // rest after duplicate version
    // Let me just rebuild cleanly:
    build_clean_datagram(num_samples)
}

fn build_clean_datagram(num_samples: u32) -> Vec<u8> {
    let mut data = Vec::new();

    // Datagram header
    data.extend_from_slice(&5u32.to_be_bytes()); // version 5
    data.extend_from_slice(&1u32.to_be_bytes()); // address type IPv4
    data.extend_from_slice(&[10, 0, 0, 1]); // agent address
    data.extend_from_slice(&0u32.to_be_bytes()); // sub_agent_id
    data.extend_from_slice(&42u32.to_be_bytes()); // sequence_number
    data.extend_from_slice(&1000u32.to_be_bytes()); // uptime
    data.extend_from_slice(&num_samples.to_be_bytes());

    for seq in 0..num_samples {
        let sample = build_flow_sample(seq + 1);
        data.extend_from_slice(&1u32.to_be_bytes()); // enterprise=0, format=1
        data.extend_from_slice(&(sample.len() as u32).to_be_bytes());
        data.extend(&sample);
    }

    data
}

fn build_flow_sample(seq: u32) -> Vec<u8> {
    let mut records = Vec::new();

    // Record 1: Raw Packet Header (format=1)
    {
        let header_bytes = [0xAAu8; 64]; // fake 64-byte packet header
        let mut rec = Vec::new();
        rec.extend_from_slice(&1u32.to_be_bytes()); // header_protocol (ethernet)
        rec.extend_from_slice(&128u32.to_be_bytes()); // frame_length
        rec.extend_from_slice(&0u32.to_be_bytes()); // stripped
        rec.extend_from_slice(&(header_bytes.len() as u32).to_be_bytes());
        rec.extend_from_slice(&header_bytes);
        // record header
        records.extend_from_slice(&1u32.to_be_bytes()); // format=1
        records.extend_from_slice(&(rec.len() as u32).to_be_bytes());
        records.extend(rec);
    }

    // Record 2: Extended Switch (format=1001)
    {
        let mut rec = Vec::new();
        rec.extend_from_slice(&100u32.to_be_bytes()); // src_vlan
        rec.extend_from_slice(&0u32.to_be_bytes()); // src_priority
        rec.extend_from_slice(&200u32.to_be_bytes()); // dst_vlan
        rec.extend_from_slice(&0u32.to_be_bytes()); // dst_priority
        records.extend_from_slice(&((0 << 12) | 1001u32).to_be_bytes());
        records.extend_from_slice(&(rec.len() as u32).to_be_bytes());
        records.extend(rec);
    }

    // Record 3: Extended Router (format=1002)
    {
        let mut rec = Vec::new();
        rec.extend_from_slice(&1u32.to_be_bytes()); // address type IPv4
        rec.extend_from_slice(&[192, 168, 1, 1]); // next_hop
        rec.extend_from_slice(&24u32.to_be_bytes()); // src_mask
        rec.extend_from_slice(&24u32.to_be_bytes()); // dst_mask
        records.extend_from_slice(&((0 << 12) | 1002u32).to_be_bytes());
        records.extend_from_slice(&(rec.len() as u32).to_be_bytes());
        records.extend(rec);
    }

    // Record 4: Extended TCP Info (format=2209)
    {
        let mut rec = Vec::new();
        rec.extend_from_slice(&2u32.to_be_bytes()); // direction=sent
        rec.extend_from_slice(&1460u32.to_be_bytes()); // snd_mss
        rec.extend_from_slice(&1460u32.to_be_bytes()); // rcv_mss
        rec.extend_from_slice(&5u32.to_be_bytes()); // unacked
        rec.extend_from_slice(&0u32.to_be_bytes()); // lost
        rec.extend_from_slice(&0u32.to_be_bytes()); // retrans
        rec.extend_from_slice(&1500u32.to_be_bytes()); // pmtu
        rec.extend_from_slice(&10000u32.to_be_bytes()); // rtt
        rec.extend_from_slice(&5000u32.to_be_bytes()); // rttvar
        rec.extend_from_slice(&65535u32.to_be_bytes()); // snd_cwnd
        rec.extend_from_slice(&3u32.to_be_bytes()); // reordering
        rec.extend_from_slice(&8000u32.to_be_bytes()); // min_rtt
        records.extend_from_slice(&((0 << 12) | 2209u32).to_be_bytes());
        records.extend_from_slice(&(rec.len() as u32).to_be_bytes());
        records.extend(rec);
    }

    let num_records: u32 = 4;

    let mut sample = Vec::new();
    sample.extend_from_slice(&seq.to_be_bytes()); // sequence_number
    sample.extend_from_slice(&3u32.to_be_bytes()); // source_id
    sample.extend_from_slice(&256u32.to_be_bytes()); // sampling_rate
    sample.extend_from_slice(&10000u32.to_be_bytes()); // sample_pool
    sample.extend_from_slice(&0u32.to_be_bytes()); // drops
    sample.extend_from_slice(&1u32.to_be_bytes()); // input
    sample.extend_from_slice(&2u32.to_be_bytes()); // output
    sample.extend_from_slice(&num_records.to_be_bytes());
    sample.extend(records);

    sample
}

fn bench_throughput(c: &mut Criterion) {
    let datagram = build_realistic_datagram();
    let parser = SflowParser::default();

    // Verify it parses correctly
    let result = parser.parse_bytes(&datagram);
    assert!(
        result.error.is_none(),
        "Test datagram should parse without error"
    );
    assert_eq!(result.datagrams.len(), 1);
    assert_eq!(result.datagrams[0].samples.len(), 8);

    let mut group = c.benchmark_group("throughput");

    // Single datagram throughput
    group.throughput(Throughput::Bytes(datagram.len() as u64));
    group.bench_with_input(
        BenchmarkId::new("single_datagram", datagram.len()),
        &datagram,
        |b, data| {
            b.iter(|| parser.parse_bytes(data));
        },
    );

    // Simulate batch: parse the same datagram N times in sequence
    let batch_count = 100;
    let batch: Vec<u8> = std::iter::repeat_n(&datagram, batch_count)
        .flat_map(|d| d.iter().copied())
        .collect();
    // Note: parse_bytes handles multiple concatenated datagrams
    group.throughput(Throughput::Bytes(batch.len() as u64));
    group.bench_with_input(
        BenchmarkId::new("batch_100_datagrams", batch.len()),
        &batch,
        |b, data| {
            b.iter(|| parser.parse_bytes(data));
        },
    );

    group.finish();
}

criterion_group!(benches, bench_throughput);
criterion_main!(benches);
