## 1. Project Scaffolding

- [x] 1.1 Convert src/main.rs to src/lib.rs with module declarations
- [x] 1.2 Update Cargo.toml with runtime dependencies (nom, nom-derive, serde, byteorder, mac_address), dev dependencies (criterion, insta, tokio, hex, serde_json, pcap-parser, etherparse), package metadata (license, description, repository), and edition 2024
- [x] 1.3 Create rustfmt.toml (max_width=96, reorder_imports=true)
- [x] 1.4 Create deny.toml with license allowlist and advisory checks
- [x] 1.5 Create .gitignore (target/, Cargo.lock patterns)

## 2. Error Types and Core Types

- [x] 2.1 Create src/error.rs with SflowError enum (Incomplete, UnsupportedVersion, ParseError, TooManySamples) implementing Display, Debug, Clone, Serialize, Deserialize, PartialEq
- [x] 2.2 Define AddressType enum (IPv4/IPv6) in src/datagram.rs with serde support (human-readable IP serialization)

## 3. Datagram Parsing

- [x] 3.1 Create src/datagram.rs with SflowDatagram struct (header fields + Vec<SflowSample>) and nom parser for the v5 header (version, agent address type/value, sub_agent_id, sequence_number, uptime, num_samples)
- [x] 3.2 Implement version validation (reject non-v5) and agent address dispatch (type=1 → IPv4, type=2 → IPv6)
- [x] 3.3 Implement sample iteration loop parsing num_samples entries with enterprise/format dispatch

## 4. Sample Types

- [x] 4.1 Create src/samples/mod.rs with SflowSample enum (FlowSample, CounterSample, ExpandedFlowSample, ExpandedCounterSample, Unknown)
- [x] 4.2 Create src/samples/flow_sample.rs with FlowSample struct (sequence_number, source_id, sampling_rate, sample_pool, drops, input, output, records) and nom parser
- [x] 4.3 Add ExpandedFlowSample struct (separate source_id_type/source_id_index, expanded input/output format/value fields) and nom parser in the same file
- [x] 4.4 Create src/samples/counter_sample.rs with CounterSample struct (sequence_number, source_id, records) and nom parser
- [x] 4.5 Add ExpandedCounterSample struct (separate source_id_type/source_id_index) and nom parser in the same file
- [x] 4.6 Implement flow record dispatch in flow_sample.rs (read enterprise/format per record, dispatch to flow_records parsers)
- [x] 4.7 Implement counter record dispatch in counter_sample.rs (read enterprise/format per record, dispatch to counter_records parsers)

## 5. Flow Record Types

- [x] 5.1 Create src/flow_records/mod.rs with FlowRecord enum (RawPacketHeader, SampledEthernet, SampledIpv4, SampledIpv6, ExtendedSwitch, ExtendedRouter, ExtendedGateway, ExtendedUser, ExtendedUrl, Unknown)
- [x] 5.2 Implement RawPacketHeader parser (src/flow_records/raw_packet_header.rs) — header_protocol, frame_length, stripped, header_length, header bytes
- [x] 5.3 Implement SampledEthernet parser (src/flow_records/sampled_ethernet.rs) — src_mac, dst_mac, eth_type
- [x] 5.4 Implement SampledIpv4 parser (src/flow_records/sampled_ipv4.rs) — length, protocol, src_ip, dst_ip, src_port, dst_port, tcp_flags, tos
- [x] 5.5 Implement SampledIpv6 parser (src/flow_records/sampled_ipv6.rs) — length, protocol, src_ip, dst_ip, src_port, dst_port, tcp_flags, priority
- [x] 5.6 Implement ExtendedSwitch parser (src/flow_records/extended_switch.rs) — src_vlan, src_priority, dst_vlan, dst_priority
- [x] 5.7 Implement ExtendedRouter parser (src/flow_records/extended_router.rs) — next_hop (AddressType), src_mask_len, dst_mask_len
- [x] 5.8 Implement ExtendedGateway parser (src/flow_records/extended_gateway.rs) — next_hop, AS fields, AS path segments, communities
- [x] 5.9 Implement ExtendedUser parser (src/flow_records/extended_user.rs) — src/dst charset, user strings
- [x] 5.10 Implement ExtendedUrl parser (src/flow_records/extended_url.rs) — direction, url string, host string

## 6. Counter Record Types

- [x] 6.1 Create src/counter_records/mod.rs with CounterRecord enum (GenericInterface, EthernetInterface, TokenRing, Vlan, Processor, Unknown)
- [x] 6.2 Implement GenericInterface parser (src/counter_records/generic_interface.rs) — 19 fields including 64-bit octets and speed
- [x] 6.3 Implement EthernetInterface parser (src/counter_records/ethernet_interface.rs) — 13 dot3 statistics fields
- [x] 6.4 Implement TokenRing parser (src/counter_records/token_ring.rs) — IEEE 802.5 statistics
- [x] 6.5 Implement Vlan parser (src/counter_records/vlan.rs) — vlan_id, octets, packet counts, discards
- [x] 6.6 Implement Processor parser (src/counter_records/processor.rs) — CPU percentages, memory values

## 7. Public API

- [x] 7.1 Create SflowParser struct and SflowParserBuilder in src/lib.rs with default() and builder() constructors
- [x] 7.2 Implement parse_bytes(&self, packet: &[u8]) -> ParseResult method with partial-result error handling
- [x] 7.3 Define ParseResult struct (datagrams: Vec<SflowDatagram>, error: Option<SflowError>)
- [x] 7.4 Add re-exports in lib.rs for all public types (SflowDatagram, SflowSample, FlowRecord, CounterRecord, AddressType, SflowError, ParseResult)
- [x] 7.5 Ensure all public types derive Debug, Clone, PartialEq, Serialize, Deserialize

## 8. Unit Tests

- [x] 8.1 Create src/tests.rs with unit tests for datagram header parsing (IPv4 agent, IPv6 agent, bad version)
- [x] 8.2 Add unit tests for flow sample and expanded flow sample parsing
- [x] 8.3 Add unit tests for counter sample and expanded counter sample parsing
- [x] 8.4 Add unit tests for each flow record type (raw packet header, sampled ethernet, sampled IPv4/IPv6, extended switch/router/gateway/user/url)
- [x] 8.5 Add unit tests for each counter record type (generic interface, ethernet, token ring, VLAN, processor)
- [x] 8.6 Add unit tests for unknown record handling (unknown sample type, unknown flow record, unknown counter record)

## 9. Integration Tests

- [x] 9.1 Create tests/basic_parsing.rs — parse complete datagrams with multiple sample types
- [x] 9.2 Create tests/serialization.rs — JSON round-trip for all types
- [x] 9.3 Create tests/error_handling.rs — truncated input, bad version, max samples exceeded
- [x] 9.4 Create tests/multi_sample.rs — datagrams with mixed flow and counter samples

## 10. Examples

- [x] 10.1 Create examples/sflow_udp_listener_single_threaded.rs — basic UDP listener on port 6343
- [x] 10.2 Create examples/sflow_udp_listener_multi_threaded.rs — thread-pool UDP listener
- [x] 10.3 Create examples/sflow_udp_listener_tokio.rs — async/await UDP listener
- [x] 10.4 Create examples/sflow_pcap.rs — parse sFlow from pcap files

## 11. Benchmarks and Fuzzing

- [x] 11.1 Create benches/sflow_parser_bench.rs — Criterion benchmark for full datagram parsing
- [x] 11.2 Create benches/flow_sample_bench.rs — benchmark for flow sample parsing
- [x] 11.3 Create benches/counter_sample_bench.rs — benchmark for counter sample parsing
- [x] 11.4 Create fuzz/fuzz_targets/fuzz_target_1.rs — fuzz parse_bytes with arbitrary input

## 12. CI/CD

- [x] 12.1 Create .github/workflows/rust.yml — fmt, clippy, build, test, doc-test, bench jobs
- [x] 12.2 Create .github/workflows/security-audit.yml — daily cargo-audit + cargo-deny
- [x] 12.3 Create .github/dependabot.yml — weekly Cargo and Actions updates
