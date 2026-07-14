## Context

This is a greenfield Rust library crate for parsing sFlow v5 datagrams (RFC 3176). The project mirrors the conventions of the sibling `netflow_parser` crate — same parsing library (nom), same API style (builder pattern), same CI/CD approach, same dev tooling. sFlow v5 is a self-describing protocol: each datagram contains a header followed by a variable number of samples, and each sample contains a variable number of records. Unlike NetFlow V9/IPFIX, sFlow does not use templates — all structure is inline, making parsing stateless.

All sFlow v5 values are big-endian (network byte order). The protocol uses an enterprise/format encoding scheme: record types are identified by `(enterprise_number, format)` pairs, where enterprise 0 is the standard sFlow MIB and non-zero enterprises allow vendor extensions.

## Goals / Non-Goals

**Goals:**

- Parse sFlow v5 datagrams from raw bytes with zero-copy where possible
- Support all four sample types: Flow Sample, Counter Sample, Expanded Flow Sample, Expanded Counter Sample
- Support all standard (enterprise 0) flow and counter record types
- Provide an ergonomic public API matching `netflow_parser` conventions (builder, error type, parse result, serde)
- Full project infrastructure: CI, tests, examples, benchmarks, fuzzing
- Stateless parsing — no template caches or mutable parser state needed (unlike NetFlow V9/IPFIX)

**Non-Goals:**

- sFlow v2/v4 support (legacy, rarely deployed)
- Vendor-specific enterprise record parsing (can be added later as a feature)
- Flow export / packet construction (read-only parser)
- Integration with `netflow_parser` (separate crate, no shared dependency)
- Async parsing or streaming APIs (parse complete datagrams only)

## Decisions

### 1. Parsing library: `nom` + `nom-derive`

**Choice**: Use `nom` parser combinators with `nom-derive` procedural macros.

**Rationale**: Consistent with `netflow_parser`. nom is battle-tested for binary protocol parsing in Rust, provides excellent error reporting, and `nom-derive` reduces boilerplate for fixed-structure types. sFlow v5's fixed structures are a perfect fit for declarative `#[nom]` attribute parsing.

**Alternatives considered**:
- `binread`/`binrw` — good for binary formats but less ecosystem alignment with netflow_parser
- Manual parsing — more control but significantly more boilerplate
- `winnow` — modern nom successor, but breaking consistency with the sibling crate

### 2. Module structure

**Choice**: Organize by protocol hierarchy — datagram → samples → records.

```
src/
├── lib.rs                  # SflowParser, public API, re-exports
├── error.rs                # SflowError enum
├── datagram.rs             # SflowDatagram header parsing
├── samples/
│   ├── mod.rs              # SflowSample enum, dispatch
│   ├── flow_sample.rs      # FlowSample + ExpandedFlowSample
│   └── counter_sample.rs   # CounterSample + ExpandedCounterSample
├── flow_records/
│   ├── mod.rs              # FlowRecord enum, dispatch
│   ├── raw_packet_header.rs
│   ├── sampled_ethernet.rs
│   ├── sampled_ipv4.rs
│   ├── sampled_ipv6.rs
│   ├── extended_switch.rs
│   ├── extended_router.rs
│   ├── extended_gateway.rs
│   ├── extended_user.rs
│   └── extended_url.rs
├── counter_records/
│   ├── mod.rs              # CounterRecord enum, dispatch
│   ├── generic_interface.rs
│   ├── ethernet_interface.rs
│   ├── token_ring.rs
│   ├── vlan.rs
│   ├── processor.rs
│   └── host.rs             # Host description, CPU, memory, disk, network
└── tests.rs                # Unit tests
```

**Rationale**: Mirrors the natural sFlow protocol nesting. Each record type gets its own file to keep files focused and easy to navigate. The `samples/` and `flow_records/`/`counter_records/` split parallels how `netflow_parser` separates `static_versions/` from `variable_versions/`.

**Alternatives considered**:
- Flat structure (all in lib.rs) — doesn't scale with 15+ record types
- Single `records.rs` — too large, mixes flow and counter concerns

### 3. Enterprise/format dispatch pattern

**Choice**: Parse the `(enterprise, format)` pair from each record header, then dispatch to the appropriate parser via match. Unknown enterprise/format pairs are captured as `UnknownRecord { enterprise, format, data: Vec<u8> }` rather than returning an error.

**Rationale**: sFlow uses `enterprise << 12 | format` encoding in the record data format field. Graceful handling of unknown records is essential for forward compatibility — new record types are regularly added by vendors. This matches `netflow_parser`'s approach of parsing unknown fields as raw bytes (the `parse_unknown_fields` feature).

### 4. Stateless parser design

**Choice**: `SflowParser` is stateless — each `parse_bytes()` call is independent with no retained state between calls.

**Rationale**: Unlike NetFlow V9/IPFIX which requires template caches, sFlow v5 is fully self-describing. Every datagram can be parsed in isolation. This simplifies the API significantly — no builder configuration is needed for basic parsing. A builder is still provided for optional settings (e.g., max sample count limits for DoS protection).

### 5. Error handling

**Choice**: `SflowError` enum with variants for common failure modes, following `netflow_parser`'s pattern.

```rust
pub enum SflowError {
    Incomplete { available: usize, context: String },
    UnsupportedVersion { version: u32 },
    ParseError { offset: usize, context: String, kind: String },
    TooManySamples { count: u32, max: u32 },
}
```

`ParseResult` contains `Vec<SflowDatagram>` + optional `SflowError`, allowing partial parse results.

**Rationale**: Consistent with `netflow_parser`. Returning partial results on error is important for network monitoring — a single malformed sample shouldn't discard the entire datagram.

### 6. Serde integration

**Choice**: Derive `Serialize` and `Deserialize` on all public types. Use `serde` with `derive` feature.

**Rationale**: Enables JSON output, logging, and interop. Matches `netflow_parser`. IP addresses serialize as strings, MAC addresses as colon-separated hex, byte arrays as hex strings.

### 7. Address handling

**Choice**: Use `std::net::Ipv4Addr` and `std::net::Ipv6Addr` for IP addresses. The agent address in the datagram header is an enum (`AddressType::IPv4(Ipv4Addr)` / `AddressType::IPv6(Ipv6Addr)`) since sFlow encodes the address type explicitly.

**Rationale**: Standard library types are idiomatic, well-integrated with serde, and avoid external dependencies for IP handling.

### 8. Project infrastructure mirroring `netflow_parser`

**Choice**: Replicate the CI/CD and tooling setup:
- `rustfmt.toml`: `max_width = 96`, `reorder_imports = true`
- `deny.toml`: License allowlist (MIT, Apache-2.0), advisory checks
- `.github/workflows/rust.yml`: fmt, clippy, build, test, doc-test, bench
- `.github/workflows/security-audit.yml`: Daily cargo-audit + cargo-deny
- `dependabot.yml`: Weekly Cargo + Actions updates
- Examples: UDP listener (single-threaded, multi-threaded, tokio), pcap parsing
- Benchmarks: Criterion-based, per-sample-type benchmarking
- Fuzzing: cargo-fuzz target for main parser entry point

**Rationale**: Exact parity with `netflow_parser` ensures consistent quality standards and makes both crates feel like parts of the same ecosystem.

## Risks / Trade-offs

**[Incomplete record coverage]** → Start with the most common record types (raw packet header, generic interface, ethernet, VLAN, processor). Less common types (token ring, host records) can be added incrementally. Unknown records are always captured as raw bytes.

**[sFlow v5 spec ambiguity]** → Some record fields have implementation-specific interpretations (e.g., extended gateway AS path encoding). Mitigation: follow the sFlow.org reference implementation behavior and document deviations.

**[No template state means no scoped parser]** → Unlike `netflow_parser`, there's no need for `ScopedParser` or per-source isolation since parsing is stateless. This is a simplification, not a risk, but worth noting for API parity expectations.

**[nom-derive limitations]** → Some sFlow structures have variable-length fields dependent on preceding values (e.g., agent address length depends on address type). These require manual nom parser implementations rather than `#[nom]` derive. Mitigation: use derive where possible, manual parsers for variable structures.
