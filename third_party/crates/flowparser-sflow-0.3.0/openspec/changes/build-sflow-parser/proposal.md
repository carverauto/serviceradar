## Why

There is no maintained, idiomatic Rust library for parsing sFlow (v5) datagrams. The existing `netflow_parser` crate covers NetFlow V5/V7/V9 and IPFIX but not sFlow, which is a distinct sampling protocol (RFC 3176) widely deployed in network monitoring. Building an `sflow_parser` crate complements `netflow_parser` and provides a consistent Rust-native option for the sFlow protocol, following the same project conventions and quality standards.

## What Changes

- Create a new Rust library crate (`sflow_parser`) for parsing sFlow v5 datagrams
- Implement parsing of the sFlow v5 datagram header (version, agent address, sub-agent ID, sequence number, uptime, sample count)
- Implement parsing of all four sample types: Flow Sample, Counter Sample, Expanded Flow Sample, Expanded Counter Sample
- Implement parsing of flow record types (raw packet header, sampled ethernet, sampled IPv4, sampled IPv6, extended switch, extended router, extended gateway, extended user, extended URL)
- Implement parsing of counter record types (generic interface, ethernet interface, token ring, VLAN, processor, host description, host adapters, etc.)
- Provide a public API with builder pattern, error handling, and iteration — mirroring `netflow_parser` conventions
- Add serde serialization/deserialization support for all types
- Set up project infrastructure: GitHub Actions CI (fmt, clippy, test, bench, fuzz, security audit), examples, benchmarks, integration tests, rustfmt.toml, deny.toml

## Capabilities

### New Capabilities

- `datagram-parsing`: Core sFlow v5 datagram structure — header parsing, version detection, agent address handling (IPv4/IPv6), sample dispatch by enterprise/format
- `flow-samples`: Flow Sample and Expanded Flow Sample parsing — sample headers, flow record type dispatch, and all standard flow record formats (raw packet header, extended switch, extended router, extended gateway, etc.)
- `counter-samples`: Counter Sample and Expanded Counter Sample parsing — sample headers, counter record type dispatch, and all standard counter record formats (generic interface, ethernet, VLAN, processor, etc.)
- `public-api`: Parser API design — builder pattern, error types, parse result type, iterator API, serde integration, and `nom`-based parsing approach consistent with `netflow_parser`
- `project-infrastructure`: CI/CD pipelines, examples (UDP listeners, pcap parsing), benchmarks, fuzz targets, integration tests, configuration files (rustfmt.toml, deny.toml, dependabot.yml), and documentation

### Modified Capabilities

_None — this is a greenfield project._

## Impact

- **New crate**: `sflow_parser` as a standalone library crate (lib.rs, not main.rs)
- **Dependencies**: `nom`, `nom-derive`, `serde`, `byteorder`, `mac_address` (runtime); `criterion`, `insta`, `tokio`, `hex`, `serde_json` (dev)
- **CI/CD**: New GitHub Actions workflows for build/test/bench/fuzz/security
- **Public API surface**: `SflowParser`, `SflowDatagram`, `SflowSample`, flow/counter record enums, error types
- **No impact on `netflow_parser`** — this is a separate, independent crate
