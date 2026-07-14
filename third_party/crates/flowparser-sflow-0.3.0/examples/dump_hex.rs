//! Temporary utility to extract specific sFlow UDP payloads from a pcap file
//! as Wireshark-style hex dumps for use as test data.
//!
//! Usage: cargo run --example dump_hex -- <pcap-file>

#[allow(unused_imports)]
use flowparser_sflow::counter_records::{
    CounterRecord, EthernetInterface, GenericInterface, Processor, TokenRing, Vlan,
};
use flowparser_sflow::datagram::AddressType;
#[allow(unused_imports)]
use flowparser_sflow::flow_records::{
    ExtendedGateway, ExtendedRouter, ExtendedSwitch, ExtendedUrl, ExtendedUser, FlowRecord,
    RawPacketHeader, SampledEthernet, SampledIpv4, SampledIpv6,
};
use flowparser_sflow::samples::{
    CounterSample, ExpandedCounterSample, ExpandedFlowSample, FlowSample,
};
use flowparser_sflow::{SflowDatagram, SflowParser, SflowSample};
use pcap_parser::traits::PcapReaderIterator;
use pcap_parser::*;
use std::fs::File;
use std::io::BufReader;
use std::net::Ipv4Addr;

// ── hex dump ────────────────────────────────────────────────────────────────

fn hex_dump(data: &[u8]) {
    for (i, chunk) in data.chunks(16).enumerate() {
        print!("{:04X}   ", i * 16);
        for (j, byte) in chunk.iter().enumerate() {
            print!("{:02x} ", byte);
            if j == 7 {
                print!(" ");
            }
        }
        println!();
    }
}

// ── pretty-print helpers ────────────────────────────────────────────────────

fn fmt_addr(a: &AddressType) -> String {
    match a {
        AddressType::IPv4(ip) => ip.to_string(),
        AddressType::IPv6(ip) => ip.to_string(),
    }
}

fn print_datagram_header(dg: &SflowDatagram) {
    println!(
        "Agent: {}, seq={}, uptime={}, sub_agent={}",
        fmt_addr(&dg.agent_address),
        dg.sequence_number,
        dg.uptime,
        dg.sub_agent_id,
    );
}

fn print_flow_record(idx: usize, rec: &FlowRecord) {
    match rec {
        FlowRecord::RawPacketHeader(RawPacketHeader {
            header_protocol,
            frame_length,
            stripped,
            header_length,
            header,
        }) => {
            println!(
                "  Record[{idx}]: RawPacketHeader {{ proto={header_protocol}, frame_len={frame_length}, stripped={stripped}, hdr_len={header_length}, header=[{} bytes] }}",
                header.len()
            );
        }
        FlowRecord::SampledEthernet(SampledEthernet {
            length,
            src_mac,
            dst_mac,
            eth_type,
        }) => {
            println!(
                "  Record[{idx}]: SampledEthernet {{ length={length}, src_mac={src_mac}, dst_mac={dst_mac}, eth_type={eth_type} }}"
            );
        }
        FlowRecord::SampledIpv4(SampledIpv4 {
            length,
            protocol,
            src_ip,
            dst_ip,
            src_port,
            dst_port,
            tcp_flags,
            tos,
        }) => {
            println!(
                "  Record[{idx}]: SampledIpv4 {{ length={length}, protocol={protocol}, src_ip={src_ip}, dst_ip={dst_ip}, src_port={src_port}, dst_port={dst_port}, tcp_flags={tcp_flags}, tos={tos} }}"
            );
        }
        FlowRecord::SampledIpv6(SampledIpv6 {
            length,
            protocol,
            src_ip,
            dst_ip,
            src_port,
            dst_port,
            tcp_flags,
            priority,
        }) => {
            println!(
                "  Record[{idx}]: SampledIpv6 {{ length={length}, protocol={protocol}, src_ip={src_ip}, dst_ip={dst_ip}, src_port={src_port}, dst_port={dst_port}, tcp_flags={tcp_flags}, priority={priority} }}"
            );
        }
        FlowRecord::ExtendedSwitch(ExtendedSwitch {
            src_vlan,
            src_priority,
            dst_vlan,
            dst_priority,
        }) => {
            println!(
                "  Record[{idx}]: ExtendedSwitch {{ src_vlan={src_vlan}, src_pri={src_priority}, dst_vlan={dst_vlan}, dst_pri={dst_priority} }}"
            );
        }
        FlowRecord::ExtendedRouter(ExtendedRouter {
            next_hop,
            src_mask_len,
            dst_mask_len,
        }) => {
            println!(
                "  Record[{idx}]: ExtendedRouter {{ next_hop={}, src_mask_len={src_mask_len}, dst_mask_len={dst_mask_len} }}",
                fmt_addr(next_hop)
            );
        }
        FlowRecord::ExtendedGateway(ExtendedGateway {
            next_hop,
            as_number,
            src_as,
            src_peer_as,
            as_path_segments,
            communities,
        }) => {
            let segs: Vec<String> = as_path_segments
                .iter()
                .map(|s| format!("{{type={}, values={:?}}}", s.segment_type, s.values))
                .collect();
            println!(
                "  Record[{idx}]: ExtendedGateway {{ next_hop={}, as={as_number}, src_as={src_as}, src_peer_as={src_peer_as}, segments=[{}], communities={communities:?} }}",
                fmt_addr(next_hop),
                segs.join(", ")
            );
        }
        FlowRecord::ExtendedUser(ExtendedUser {
            src_charset,
            src_user,
            dst_charset,
            dst_user,
        }) => {
            println!(
                "  Record[{idx}]: ExtendedUser {{ src_charset={src_charset}, src_user=\"{src_user}\", dst_charset={dst_charset}, dst_user=\"{dst_user}\" }}"
            );
        }
        FlowRecord::ExtendedUrl(ExtendedUrl {
            direction,
            url,
            host,
        }) => {
            println!(
                "  Record[{idx}]: ExtendedUrl {{ direction={direction}, url=\"{url}\", host=\"{host}\" }}"
            );
        }
        FlowRecord::Unknown {
            enterprise,
            format,
            data,
        } => {
            println!(
                "  Record[{idx}]: Unknown {{ enterprise={enterprise}, format={format}, data_len={} }}",
                data.len()
            );
        }
        other => {
            println!("  Record[{idx}]: {other:?}");
        }
    }
}

fn print_counter_record(idx: usize, rec: &CounterRecord) {
    match rec {
        CounterRecord::GenericInterface(g) => {
            println!(
                "  Record[{idx}]: GenericInterface {{ if_index={}, if_type={}, if_speed={}, if_direction={}, if_status={}, if_in_octets={}, if_in_ucast_pkts={}, if_in_multicast_pkts={}, if_in_broadcast_pkts={}, if_in_discards={}, if_in_errors={}, if_in_unknown_protos={}, if_out_octets={}, if_out_ucast_pkts={}, if_out_multicast_pkts={}, if_out_broadcast_pkts={}, if_out_discards={}, if_out_errors={}, if_promiscuous_mode={} }}",
                g.if_index,
                g.if_type,
                g.if_speed,
                g.if_direction,
                g.if_status,
                g.if_in_octets,
                g.if_in_ucast_pkts,
                g.if_in_multicast_pkts,
                g.if_in_broadcast_pkts,
                g.if_in_discards,
                g.if_in_errors,
                g.if_in_unknown_protos,
                g.if_out_octets,
                g.if_out_ucast_pkts,
                g.if_out_multicast_pkts,
                g.if_out_broadcast_pkts,
                g.if_out_discards,
                g.if_out_errors,
                g.if_promiscuous_mode,
            );
        }
        CounterRecord::EthernetInterface(e) => {
            println!(
                "  Record[{idx}]: EthernetInterface {{ alignment_errors={}, fcs_errors={}, single_collision_frames={}, multiple_collision_frames={}, sqe_test_errors={}, deferred_transmissions={}, late_collisions={}, excessive_collisions={}, internal_mac_transmit_errors={}, carrier_sense_errors={}, frame_too_longs={}, internal_mac_receive_errors={}, symbol_errors={} }}",
                e.dot3_stats_alignment_errors,
                e.dot3_stats_fcs_errors,
                e.dot3_stats_single_collision_frames,
                e.dot3_stats_multiple_collision_frames,
                e.dot3_stats_sqe_test_errors,
                e.dot3_stats_deferred_transmissions,
                e.dot3_stats_late_collisions,
                e.dot3_stats_excessive_collisions,
                e.dot3_stats_internal_mac_transmit_errors,
                e.dot3_stats_carrier_sense_errors,
                e.dot3_stats_frame_too_longs,
                e.dot3_stats_internal_mac_receive_errors,
                e.dot3_stats_symbol_errors,
            );
        }
        CounterRecord::TokenRing(t) => {
            println!(
                "  Record[{idx}]: TokenRing {{ line_errors={}, burst_errors={}, ac_errors={}, abort_trans_errors={}, internal_errors={}, lost_frame_errors={}, receive_congestions={}, frame_copied_errors={}, token_errors={}, soft_errors={}, hard_errors={}, signal_loss={}, transmit_beacons={}, recoverys={}, lobe_wires={}, removes={}, singles={}, freq_errors={} }}",
                t.dot5_stats_line_errors,
                t.dot5_stats_burst_errors,
                t.dot5_stats_ac_errors,
                t.dot5_stats_abort_trans_errors,
                t.dot5_stats_internal_errors,
                t.dot5_stats_lost_frame_errors,
                t.dot5_stats_receive_congestions,
                t.dot5_stats_frame_copied_errors,
                t.dot5_stats_token_errors,
                t.dot5_stats_soft_errors,
                t.dot5_stats_hard_errors,
                t.dot5_stats_signal_loss,
                t.dot5_stats_transmit_beacons,
                t.dot5_stats_recoverys,
                t.dot5_stats_lobe_wires,
                t.dot5_stats_removes,
                t.dot5_stats_singles,
                t.dot5_stats_freq_errors,
            );
        }
        CounterRecord::Vlan(v) => {
            println!(
                "  Record[{idx}]: Vlan {{ vlan_id={}, octets={}, ucast_pkts={}, multicast_pkts={}, broadcast_pkts={}, discards={} }}",
                v.vlan_id,
                v.octets,
                v.ucast_pkts,
                v.multicast_pkts,
                v.broadcast_pkts,
                v.discards,
            );
        }
        CounterRecord::Processor(p) => {
            println!(
                "  Record[{idx}]: Processor {{ cpu_5s={}, cpu_1m={}, cpu_5m={}, total_memory={}, free_memory={} }}",
                p.cpu_5s, p.cpu_1m, p.cpu_5m, p.total_memory, p.free_memory,
            );
        }
        CounterRecord::Unknown {
            enterprise,
            format,
            data,
        } => {
            println!(
                "  Record[{idx}]: Unknown {{ enterprise={enterprise}, format={format}, data_len={} }}",
                data.len()
            );
        }
        other => {
            println!("  Record[{idx}]: {other:?}");
        }
    }
}

fn print_sample(idx: usize, sample: &SflowSample) {
    match sample {
        SflowSample::Flow(FlowSample {
            sequence_number,
            source_id_type,
            source_id_index,
            sampling_rate,
            sample_pool,
            drops,
            input,
            output,
            records,
        }) => {
            println!(
                "Sample[{idx}]: Flow {{ seq={sequence_number}, src_id_type={source_id_type}, src_id_index={source_id_index}, rate={sampling_rate}, pool={sample_pool}, drops={drops}, input={input}, output={output}, records={} }}",
                records.len()
            );
            for (ri, rec) in records.iter().enumerate() {
                print_flow_record(ri, rec);
            }
        }
        SflowSample::Counter(CounterSample {
            sequence_number,
            source_id_type,
            source_id_index,
            records,
        }) => {
            println!(
                "Sample[{idx}]: Counter {{ seq={sequence_number}, src_id_type={source_id_type}, src_id_index={source_id_index}, records={} }}",
                records.len()
            );
            for (ri, rec) in records.iter().enumerate() {
                print_counter_record(ri, rec);
            }
        }
        SflowSample::ExpandedFlow(ExpandedFlowSample {
            sequence_number,
            source_id_type,
            source_id_index,
            sampling_rate,
            sample_pool,
            drops,
            input_format,
            input_value,
            output_format,
            output_value,
            records,
        }) => {
            println!(
                "Sample[{idx}]: ExpandedFlow {{ seq={sequence_number}, src_id_type={source_id_type}, src_id_index={source_id_index}, rate={sampling_rate}, pool={sample_pool}, drops={drops}, input_fmt={input_format}, input_val={input_value}, output_fmt={output_format}, output_val={output_value}, records={} }}",
                records.len()
            );
            for (ri, rec) in records.iter().enumerate() {
                print_flow_record(ri, rec);
            }
        }
        SflowSample::ExpandedCounter(ExpandedCounterSample {
            sequence_number,
            source_id_type,
            source_id_index,
            records,
        }) => {
            println!(
                "Sample[{idx}]: ExpandedCounter {{ seq={sequence_number}, src_id_type={source_id_type}, src_id_index={source_id_index}, records={} }}",
                records.len()
            );
            for (ri, rec) in records.iter().enumerate() {
                print_counter_record(ri, rec);
            }
        }
        SflowSample::DiscardedPacket(flowparser_sflow::samples::DiscardedPacket {
            sequence_number,
            ds_class,
            ds_index,
            drops,
            input,
            output,
            reason,
            records,
        }) => {
            println!(
                "Sample[{idx}]: DiscardedPacket {{ seq={sequence_number}, ds_class={ds_class}, ds_index={ds_index}, drops={drops}, input={input}, output={output}, reason={reason}, records={} }}",
                records.len()
            );
            for (ri, rec) in records.iter().enumerate() {
                print_flow_record(ri, rec);
            }
        }
        SflowSample::Unknown {
            enterprise,
            format,
            data,
        } => {
            println!(
                "Sample[{idx}]: Unknown {{ enterprise={enterprise}, format={format}, data_len={} }}",
                data.len()
            );
        }
    }
}

fn print_full(label: &str, dg: &SflowDatagram, payload: &[u8]) {
    println!("\n=== {label} ===");
    print_datagram_header(dg);
    for (si, sample) in dg.samples.iter().enumerate() {
        print_sample(si, sample);
    }
    println!("HEX:");
    hex_dump(payload);
}

// ── matching helpers ────────────────────────────────────────────────────────

#[allow(dead_code)]
fn agent_ip(dg: &SflowDatagram) -> Option<Ipv4Addr> {
    match &dg.agent_address {
        AddressType::IPv4(ip) => Some(*ip),
        _ => None,
    }
}

fn has_flow_with_n_records(dg: &SflowDatagram, min: usize) -> bool {
    dg.samples.iter().any(|s| match s {
        SflowSample::Flow(f) => f.records.len() >= min,
        SflowSample::ExpandedFlow(f) => f.records.len() >= min,
        _ => false,
    })
}

fn has_counter_with_n_records(dg: &SflowDatagram, min: usize) -> bool {
    dg.samples.iter().any(|s| match s {
        SflowSample::Counter(c) => c.records.len() >= min,
        SflowSample::ExpandedCounter(c) => c.records.len() >= min,
        _ => false,
    })
}

fn has_unknown_records(dg: &SflowDatagram) -> bool {
    for sample in &dg.samples {
        match sample {
            SflowSample::Flow(f) => {
                for rec in &f.records {
                    if matches!(rec, FlowRecord::Unknown { format, .. } if *format >= 2000) {
                        return true;
                    }
                }
            }
            SflowSample::ExpandedFlow(f) => {
                for rec in &f.records {
                    if matches!(rec, FlowRecord::Unknown { format, .. } if *format >= 2000) {
                        return true;
                    }
                }
            }
            SflowSample::Counter(c) => {
                for rec in &c.records {
                    if matches!(rec, CounterRecord::Unknown { format, .. } if *format >= 2000) {
                        return true;
                    }
                }
            }
            SflowSample::ExpandedCounter(c) => {
                for rec in &c.records {
                    if matches!(rec, CounterRecord::Unknown { format, .. } if *format >= 2000) {
                        return true;
                    }
                }
            }
            _ => {}
        }
    }
    false
}

fn is_mixed_3plus(dg: &SflowDatagram) -> bool {
    if dg.samples.len() < 3 {
        return false;
    }
    let has_flow = dg
        .samples
        .iter()
        .any(|s| matches!(s, SflowSample::Flow(_) | SflowSample::ExpandedFlow(_)));
    let has_counter = dg
        .samples
        .iter()
        .any(|s| matches!(s, SflowSample::Counter(_) | SflowSample::ExpandedCounter(_)));
    has_flow && has_counter
}

fn has_ethernet_counter(dg: &SflowDatagram) -> bool {
    dg.samples.iter().any(|s| {
        let records: &[CounterRecord] = match s {
            SflowSample::Counter(c) => &c.records,
            SflowSample::ExpandedCounter(c) => &c.records,
            _ => return false,
        };
        records
            .iter()
            .any(|r| matches!(r, CounterRecord::EthernetInterface(_)))
    })
}

// ── main ────────────────────────────────────────────────────────────────────

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        eprintln!("Usage: {} <pcap-file>", args[0]);
        std::process::exit(1);
    }

    let file = File::open(&args[1]).expect("Failed to open pcap file");
    let reader = BufReader::new(file);
    let mut pcap_reader =
        LegacyPcapReader::new(262_144, reader).expect("Failed to create legacy pcap reader");

    let parser = SflowParser::default();

    // Collected results: (label, datagram, raw payload)
    let mut multi_record_flow: Option<(SflowDatagram, Vec<u8>)> = None;
    let mut multi_record_counter: Option<(SflowDatagram, Vec<u8>)> = None;
    let mut unknown_records: Option<(SflowDatagram, Vec<u8>)> = None;
    let mut multi_sample_mixed: Option<(SflowDatagram, Vec<u8>)> = None;
    let mut large_datagram: Option<(SflowDatagram, Vec<u8>, usize)> = None; // (dg, payload, sample_count)
    let mut ethernet_counter: Option<(SflowDatagram, Vec<u8>)> = None;

    let mut pkt_idx: usize = 0;
    let max_pkts: usize = 200;

    loop {
        match pcap_reader.next() {
            Ok((offset, block)) => {
                // Copy packet data out so we can release the borrow before consume()
                let owned_data: Option<Vec<u8>> = if let PcapBlockOwned::Legacy(packet) = block
                {
                    Some(packet.data.to_vec())
                } else {
                    None
                };
                pcap_reader.consume(offset);

                if let Some(data) = owned_data {
                    // Past max_pkts, stop if we only need large_datagram (first-200 only)
                    if pkt_idx >= max_pkts
                        && multi_record_flow.is_some()
                        && multi_record_counter.is_some()
                        && unknown_records.is_some()
                        && multi_sample_mixed.is_some()
                        && ethernet_counter.is_some()
                    {
                        break;
                    }

                    if let Some(payload) = extract_udp_payload_owned(&data) {
                        let result = parser.parse_bytes(&payload);
                        for dg in result.datagrams {
                            // 1. multi_record_flow
                            if multi_record_flow.is_none() && has_flow_with_n_records(&dg, 2) {
                                multi_record_flow = Some((dg.clone(), payload.clone()));
                            }

                            // 2. multi_record_counter
                            if multi_record_counter.is_none()
                                && has_counter_with_n_records(&dg, 2)
                            {
                                multi_record_counter = Some((dg.clone(), payload.clone()));
                            }

                            // 3. unknown_records (format >= 2000)
                            if unknown_records.is_none() && has_unknown_records(&dg) {
                                unknown_records = Some((dg.clone(), payload.clone()));
                            }

                            // 4. multi_sample_mixed (3+ samples, flow+counter)
                            if multi_sample_mixed.is_none() && is_mixed_3plus(&dg) {
                                multi_sample_mixed = Some((dg.clone(), payload.clone()));
                            }

                            // 5. large_datagram (most samples in first 200)
                            if pkt_idx < max_pkts {
                                let count = dg.samples.len();
                                let current_max =
                                    large_datagram.as_ref().map(|(_, _, c)| *c).unwrap_or(0);
                                if count > current_max {
                                    large_datagram = Some((dg.clone(), payload.clone(), count));
                                }
                            }

                            // 6. ethernet_counter
                            if ethernet_counter.is_none() && has_ethernet_counter(&dg) {
                                ethernet_counter = Some((dg.clone(), payload.clone()));
                            }
                        }
                    }

                    pkt_idx += 1;
                }
            }
            Err(PcapError::Eof) => break,
            Err(PcapError::Incomplete(_)) => {
                pcap_reader.refill().expect("Failed to refill pcap reader");
            }
            Err(e) => {
                eprintln!("Error reading pcap: {:?}", e);
                break;
            }
        }
    }

    // ── output results ──────────────────────────────────────────────────

    println!("Scanned {pkt_idx} pcap frames\n");

    if let Some((dg, payload)) = &multi_record_flow {
        print_full("multi_record_flow", dg, payload);
    } else {
        println!("\n=== multi_record_flow ===\nNOT FOUND");
    }

    if let Some((dg, payload)) = &multi_record_counter {
        print_full("multi_record_counter", dg, payload);
    } else {
        println!("\n=== multi_record_counter ===\nNOT FOUND");
    }

    if let Some((dg, payload)) = &unknown_records {
        print_full("unknown_records", dg, payload);
    } else {
        println!("\n=== unknown_records ===\nNOT FOUND");
    }

    if let Some((dg, payload)) = &multi_sample_mixed {
        print_full("multi_sample_mixed", dg, payload);
    } else {
        println!("\n=== multi_sample_mixed ===\nNOT FOUND");
    }

    if let Some((dg, payload, count)) = &large_datagram {
        println!("\n=== large_datagram ({count} samples) ===");
        print_datagram_header(dg);
        for (si, sample) in dg.samples.iter().enumerate() {
            print_sample(si, sample);
        }
        println!("HEX:");
        hex_dump(payload);
    } else {
        println!("\n=== large_datagram ===\nNOT FOUND");
    }

    if let Some((dg, payload)) = &ethernet_counter {
        print_full("ethernet_counter", dg, payload);
    } else {
        println!("\n=== ethernet_counter ===\nNOT FOUND");
    }
}

fn extract_udp_payload_owned(data: &[u8]) -> Option<Vec<u8>> {
    use etherparse::SlicedPacket;
    let packet = SlicedPacket::from_ethernet(data).ok()?;
    match packet.transport {
        Some(etherparse::TransportSlice::Udp(udp)) => Some(udp.payload().to_vec()),
        _ => None,
    }
}
