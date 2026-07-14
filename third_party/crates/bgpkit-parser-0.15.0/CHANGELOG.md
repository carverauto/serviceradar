# Changelog

All notable changes to this project will be documented in this file.

## v0.15.0 - 2026-01-28

### Breaking changes

* **Negative Filter Syntax Change**: Negative filters now use value-based negation instead of type-based negation
  - Old syntax (v0.14.0): `.add_filter("!origin_asn", "13335")` - **no longer supported**
  - New syntax: `.add_filter("origin_asn", "!13335")` - prefix the value with `!`
  - For multi-value filters, prefix each value: `.add_filter("origin_asns", "!13335,!15169")`
  - Mixing positive and negative values in the same filter is not allowed and will return an error
  - CLI syntax remains the same: `--filter "origin_asn!=13335"` (internally converted to value-based negation)

### New features

* **OR Logic Filters**: New filter types that accept comma-separated values with OR logic
  - `origin_asns`: Match elements from ANY of the specified origin ASNs
  - `prefixes`: Match elements for ANY of the specified prefixes (also supports `prefixes_super`, `prefixes_sub`, `prefixes_super_sub`)
  - `peer_asns`: Match elements from ANY of the specified peer ASNs
  - `peer_ips`: Now validates input and requires at least one IP address
  - Example: `.add_filter("origin_asns", "13335,15169,8075")` matches elements from Cloudflare, Google, or Microsoft
  - All multi-value filters support negation with `!` prefix on each value
  - New example `multiple_filters_or_logic.rs` demonstrating OR logic and negative filters

## v0.14.0 - 2025-12-22

### New features

* **Negative Filter Support**: Most filters now support negation by prefixing the filter type with `!`
  - `!origin_asn`: Match elements where origin AS is NOT the specified value
  - `!prefix`: Match elements where prefix is NOT the specified value
  - `!peer_ip`, `!peer_asn`, `!type`, `!as_path`, `!community`, `!ip_version`: All support negation
  - Note: Timestamp filters (`ts_start`, `ts_end`) do not support negation
  - Example: `.add_filter("!origin_asn", "13335")` matches all elements NOT from AS 13335
  - New `Filter::Negated(Box<Filter>)` variant wraps any filter to invert its match result
  - **CLI**: New `--filter` / `-f` option supports both positive and negative filter expressions
    - Positive: `--filter "origin_asn=13335"`
    - Negative: `--filter "origin_asn!=13335"`
    - Can be used multiple times: `--filter "peer_ip!=192.168.1.1" --filter "type!=w"`

* **RPKI RTR Protocol Support**: Add full support for the RPKI-to-Router (RTR) protocol
  - New `models::rpki::rtr` module with all PDU types: SerialNotify, SerialQuery, ResetQuery, CacheResponse, IPv4Prefix, IPv6Prefix, EndOfData, CacheReset, RouterKey, ErrorReport
  - New `parser::rpki::rtr` module with parsing (`parse_rtr_pdu`, `read_rtr_pdu`) and encoding (`RtrEncode` trait)
  - Support for both RTR v0 ([RFC 6810](https://datatracker.ietf.org/doc/html/rfc6810)) and v1 ([RFC 8210](https://datatracker.ietf.org/doc/html/rfc8210))
  - Comprehensive error handling with `RtrError` enum
  - New example `rtr_client.rs` demonstrating RTR client implementation with ROA fetching and route validation

## v0.13.0 - 2025-12-07

### Breaking changes

* **`RawMrtRecord` field renamed**: `raw_bytes` is now `message_bytes` to clarify it contains only the message body
  - Added new `header_bytes` field containing the raw header bytes as read from the wire
  - The `raw_bytes()` method now returns complete MRT record bytes (header + body) without re-encoding

### New features

* Add MRT record debugging and raw bytes export capabilities
  - `RawMrtRecord` now stores both `header_bytes` and `message_bytes` to enable exact byte-for-byte export without re-encoding
  - New methods on `RawMrtRecord`: `raw_bytes()`, `write_raw_bytes()`, `append_raw_bytes()`, `total_bytes_len()`
  - Added `Display` implementations for `MrtRecord`, `CommonHeader`, and `MrtMessage` for human-readable debug output
  - New examples: `mrt_debug.rs` and `extract_problematic_records.rs` demonstrating debug features
* CLI now supports record-level output and multiple output formats
  - New `--level` (`-L`) option: `elems` (default) or `records` to control output granularity
  - New `--format` (`-F`) option: `default`, `json`, `json-pretty`, or `psv`
  - Record-level output with `--level records` outputs MRT records instead of per-prefix elements
  - JSON output for records provides full structured data for debugging
* Add `UpdateIterator` and `FallibleUpdateIterator` for iterating over BGP announcements ([#250](https://github.com/bgpkit/bgpkit-parser/issues/250))
  - New `MrtUpdate` enum supporting both BGP4MP UPDATE messages and TableDumpV2 RIB entries
  - `Bgp4MpUpdate` struct for BGP4MP UPDATE messages with metadata (timestamp, peer_ip, peer_asn)
  - `TableDumpV2Entry` struct for RIB dump entries (prefix with multiple RIB entries per peer)
  - `into_update_iter()` and `into_fallible_update_iter()` methods on `BgpkitParser`
  - Middle ground between `MrtRecord` and `BgpElem` for more efficient processing
* Add `update_messages_iter` example demonstrating the new iterator

### Testing and fuzzing

* Add cargo-fuzz harness and initial fuzz targets (mrt_record, bgp_message, parser)
* Add additional fuzz targets (BMP/OpenBMP, RIS Live, attributes, MRT header, NLRI); enable rislive feature for fuzzing

### Bug fixes

* Add bounds checks throughout parsers to avoid overread/advance/split_to panics
* Handle invalid MRT BGP4MP_ET header length gracefully (reject ET records with on-wire length < 4)
* Use originated time instead of MRT header time for TableDumpV2 messages ([#252](https://github.com/bgpkit/bgpkit-parser/pull/252))
  * added a new example study `rib_entries_age_study` demonstrating the difference between dump time and entry originated time

### Tooling and benchmarking

* Add hyperfine benchmarking script for bgpkit-parser

## v0.12.0 - 2025-10-17

### Examples and benchmarking

* Added a new runnable example: `examples/parse_single_file_parallel.rs`.
  * Parses RIB file using thread pool with batching and collecting. Two modes: worker-only parsing (default) or worker
    parsing + element conversion.
  * Includes bottleneck diagnostics, tunable parameters (batch size, workers, etc), benchmarking, and remote file
    downloading.

### Breaking changes

* change `path_id` from `u32` to `Option<u32>` for proper null handling
    * `NetworkPrefix::path_id` field now properly represents absence with `None` instead of using `0`
    * `NetworkPrefix::new()` and `NetworkPrefix::encode()` signatures updated accordingly
    * `RibEntry` now stores `path_id` for TABLE_DUMP_V2 messages with AddPath support
    * fixes issue [#217](https://github.com/bgpkit/bgpkit-parser/issues/217)

### Minumum Supported Rust Version (MSRV)

We now set a minimum supported Rust version (MSRV) of 1.87.0.

### Code improvements

#### New RFCs Supported

* added BGP Flow-Spec parsing support following RFC 8955 and RFC 8956
  * implemented complete Flow-Spec NLRI parsing for IPv4 and IPv6 Flow Specification rules
  * added support for all Flow-Spec component types (destination/source prefix, protocol, ports, ICMP, TCP flags, packet length, DSCP, fragment, flow label)
  * implemented Flow-Spec operator parsing for numeric and bitmask operations with proper semantics
  * added Flow-Spec Extended Communities for Traffic Rate, Traffic Action, Redirect, and Traffic Marking (RFC 8955)
  * created structured data model with `FlowSpecNlri`, `FlowSpecComponent`, and operator types
  * added support for IPv6-specific components including Flow Label and prefix offset encoding
  * includes test coverage with RFC example validation and round-trip encoding/decoding
  * maintains backward compatibility with existing NLRI and Extended Community parsing infrastructure
* added BGP Tunnel Encapsulation attribute parsing support following RFC 9012, RFC 5640, and RFC 8365
  * implemented complete TLV-based parsing system for BGP Tunnel Encapsulation attribute (type 23)
  * added support for all IANA-defined tunnel types (VXLAN, NVGRE, GRE, SR Policy, Geneve, etc.)
  * added support for all sub-TLV types including Color, UDP Destination Port, Tunnel Egress Endpoint, Preference
  * implemented variable-length sub-TLV encoding (1 byte for types 0-127, 2 bytes for types 128-255)
  * added helper methods for common attribute access (color, UDP port, egress endpoint, preference)
  * created structured data model with `TunnelEncapAttribute`, `TunnelEncapTlv`, and `SubTlv` types
  * added comprehensive test coverage with 7 test cases covering parsing, encoding, and error handling
  * maintains full backward compatibility with existing attribute parsing infrastructure
* added MRT geo-location extensions support following RFC 6397
  * implemented GEO_PEER_TABLE subtype (7) parsing and encoding for TABLE_DUMP_V2 format
  * added data structures for collector and peer geo-location information with WGS84 coordinates
  * implemented NaN coordinate support for privacy-protected geo-location data
  * added `GeoPeerTable` and `GeoPeer` data structures with direct float coordinate storage
  * encoding functionality follows consistent parser module pattern with other TABLE_DUMP_V2 types
  * includes test coverage with 8 test cases covering parsing, encoding, round-trip operations, and edge cases
  * maintains backward compatibility with existing TABLE_DUMP_V2 parsing and encoding infrastructure
* added comprehensive BGP Link-State parsing support following RFC 7752 and extensions
  * implemented complete Link-State NLRI parsing for Node, Link, and IPv4/IPv6 Topology Prefix types
  * added Link-State AFI (16388) and SAFI (71, 72) support for BGP-LS and BGP-LS-VPN
  * implemented TLV-based parsing system for Node, Link, and Prefix descriptors and attributes
  * added support for RFC 8571 traffic engineering performance metrics (TLVs 1114-1120)
  * added support for RFC 9085 Segment Routing extensions (TLVs 1170-1172, 1174)
  * added support for RFC 9294 Application-Specific Link Attributes (TLV 1122)
  * created structured data model with helper methods for common attribute access
  * maintains backward compatibility with non-breaking optional field additions
* add support for RFC 8654 Extended Messages
  * updated message length validation to support extended messages up to 65535 bytes
  * resolves parsing errors for large BGP messages (e.g., "invalid BGP message length 4834")
  * implemented BGP Extended Message capability (capability code 6) for parsing and encoding
  * added proper RFC 8654 validation constraints (OPEN and KEEPALIVE messages remain limited to 4096 bytes)
  * added test cases for extended message length validation and capability parsing
* implemented comprehensive BGP capabilities support for all IANA-defined capability codes with RFC support
  * added structured parsing and encoding for 7 major BGP capabilities (RFC2858, RFC2918, RFC4724, RFC6793, RFC7911, RFC8950, RFC9234)
  * implemented `MultiprotocolExtensionsCapability` for AFI/SAFI advertisement per RFC2858
  * implemented `RouteRefreshCapability` for dynamic route refresh support per RFC2918
  * implemented `GracefulRestartCapability` with restart flags and per-AF forwarding state per RFC4724
  * implemented `FourOctetAsCapability` for 4-byte AS number support per RFC6793
  * implemented `AddPathCapability` with send/receive modes for multiple path advertisement per RFC7911
  * implemented `BgpRoleCapability` with Provider/Customer/Peer/RouteServer roles per RFC9234
  * added graceful fallback to raw bytes for unrecognized or parsing-failed capabilities
  * added comprehensive test coverage with 26 test cases covering all implemented capabilities
  * updated `CapabilityValue` enum with 7 new structured capability variants
  * maintains backward compatibility while providing structured access to capability data
* added RFC 8950 support for IPv4 NLRI with IPv6 next-hops
  * extended `Safi` enum with `MplsVpn` (128) and `MulticastVpn` (129) for VPN address families
  * added `RouteDistinguisher` type for VPN next-hop parsing
  * extended `NextHopAddress` enum with `VpnIpv6` and `VpnIpv6LinkLocal` variants
  * updated `parse_mp_next_hop` to handle 24-byte and 48-byte VPN next-hops
  * enables parsing of VPN-IPv4 routes with VPN-IPv6 next-hops per RFC 8950 Section 4
* added RFC 8950 Extended Next Hop capability parsing and encoding
  * implemented `ExtendedNextHopCapability` for BGP OPEN message capability negotiation
  * supports arbitrary AFI/SAFI combinations per RFC 8950 Section 3
  * added structured capability parsing with fallback to raw bytes for compatibility
  * enables BGP speakers to advertise ability to receive cross-protocol next-hops
  * includes comprehensive validation and helper methods for capability querying
* added RFC 9069 validation warnings for BMP Local RIB peer types
  * validates Local RIB peer header requirements including zero-filled peer address and 4-byte ASN encoding
  * validates Local RIB peer up notifications for fabricated OPEN messages and VrTableName TLV presence
  * validates Local RIB route monitoring messages for proper ASN encoding
  * validation warnings logged when BMP messages do not conform to RFC 9069 specifications

#### Performance improvements

* optimized BytesMut buffer allocation patterns for better memory efficiency
    * replaced `BytesMut::with_capacity() + resize()` with `BytesMut::zeroed()` for cleaner initialization
    * added capacity pre-allocation in ASN encoding to avoid reallocations
    * replaced unnecessary BytesMut allocations with direct slice references in MRT header parsing
    * added capacity pre-allocation in MRT record encoding for optimal buffer sizing
    * fixed non-canonical PartialOrd implementation for ASN type to follow Rust idioms

#### Iterator improvements

* added fallible iterator implementations for explicit error handling
    * implemented `FallibleRecordIterator` that returns `Result<MrtRecord, ParserErrorWithBytes>`
    * implemented `FallibleElemIterator` that returns `Result<BgpElem, ParserErrorWithBytes>`
    * added `into_fallible_record_iter()` and `into_fallible_elem_iter()` methods on `BgpkitParser`
    * allows users to handle parsing errors explicitly instead of having them silently skipped
    * maintains full backward compatibility with existing error-skipping iterators
    * reorganized iterator implementations into structured `iters` module with `default` and `fallible` submodules
* added raw MRT record iteration support for record-by-record processing (PR #239)
    * added `RawRecordIterator` accessible via `into_raw_record_iter()` on `BgpkitParser`
    * separated MRT record reading from parsing for clearer error handling and improved throughput
    * moved `RawRecordIterator` into dedicated `iters::raw` module for better organization
    * added raw record parsing to `scan_mrt` example
    * added tests comparing `into_raw_record_iter()` with `record_iter()` behavior
* optimized duplicate BGP attribute detection using a fixed-size boolean array to track seen attributes (PR #239)
    * added boundary test cases for BGP attribute types

### Bug fixes

* fixed TABLE_DUMP_V2 parsing to properly store path_id when AddPath is enabled
    * previously path_id was read but discarded, now properly stored in `RibEntry`
* clarified in-bounds indexing for BGP attribute types when tracking seen attributes (PR #239)
    * index attribute type as `u8` when indexing the seen-attributes array to ensure bounds correctness
* fixed BGP OPEN message optional parameter parsing to support multiple capabilities per parameter
    * changed `ParamValue::Capability` to `ParamValue::Capacities(Vec<Capability>)` to properly handle RFC 5492 format
    * previously parser only read the first capability in each optional parameter, ignoring subsequent capabilities
    * now correctly parses all capabilities within each optional parameter
    * updated encoding logic to write all capabilities in the vector
* fixed RFC 9072 Extended Optional Parameters Length validation
    * corrected extended parameter format validation (must have non-zero opt_params_len)
    * fixed capability length parsing to always use 1-byte length per RFC 5492, not variable length
    * ensures proper RFC 9072 compliance for extended OPEN message format
* improved RFC 9069 validation for BMP Local RIB peer types
    * fixed multi-protocol capability check to specifically validate MULTIPROTOCOL_EXTENSIONS capability presence
    * previously checked for any capabilities, now correctly validates the required capability type
* added `CorruptedBgpMessage` error type for better BMP parsing error handling
    * provides more specific error information when BGP messages within BMP are corrupted

### Maintenance

* updated dependencies
* updated crate documentation and README
* removed outdated documentation files

## v0.11.1 - 2025-06-06

### Bug fixes

* Fixed an issue where IPv6 NLRI next-hop addresses were not properly passed to `BgpElem` objects.
    * The fix ensures that the `next_hop` value is extracted from either `NEXT_HOP` or `MP_REACHABLE_NLRI` BGP
      attribute, and is correctly set in the `BgpElem` object.
    * Fixes issue [#211](https://github.com/bgpkit/bgpkit-parser/issues/211)
    * Thanks [m-appel](https://github.com/m-appel) for reporting this issue!

### Maintenance

* Apply `cargo clippy` lints to the codebase
* Add more tests to improve code coverage

## v0.11.0 - 2025-02-26

### Breaking changes

* removing string format prefix like `lg:` or `ecv6` for large and extended communities
    * users who work with community value strings will have a unified experience for all community values
    * users can still use SDK to match and check different types of community values

### Highlights

* storing AS path filter regex object for reuse
    * this will improve filter performance
* allow filter messages by community values
    * by converting community values to string and do string comparison
* add `local` flag to allow local-only processing
    * this removes dependencies like `reqwest`
* support converting singleton AsSet to Vec<u32>
    * when calling `to_u32_vec_opt` on AS path object, singleton AsSet will be treated as single ASN

### Bug fixes

* fixed a bug where RIS-live withdrawal messages were not properly parsed

### Documentation

* add new RIS-Live async example

### Maintenance

* update dependencies
* add `.env` to gitignore
* remote unnecessary life-time annotations

## v0.10.11 - 2024-10-27

### Highlights

* Improved RIS Live message types and handling
* clean up dependencies
    * `models` feature is removed, and all dependencies are now required dependencies for the crate
    * `models` module no-longer requires dependencies introduced by parser, like `bytes` for encoding
* decouple `oneio` from `parser` feature
    * `oneio` is no-longer a required dependency for the parser
    * users can now use `parser` feature without `oneio` (with `--no-default-features` specified)
        * to create a new parser, one needs to user `BgpkitParser::from_reader` function instead of `BgpkitParser::new`
    * downstream libraries that only utilize parser code (such as RIS Live parsing) no-longer have to depend on oneio
* improve RouteViews Kafka example by allowing wildcard topic subscription

### Bug fixes

* fixed an issue where when merging `AS_PATH` and `AS4_PATH` segments, the parser incorrectly uses `AS_PATH` segment
  content
    * this issue may manifest as `AS_TRANS` (`AS23456`) appearing in the AS path while the correct 32-bit ASN has been
      sent in `AS4_PATH`

## v0.10.11-beta.1 - 2024-10-16

### Highlights

* Improved RIS Live message types and handling
* clean up dependencies
    * `models` feature is removed, and all dependencies are now required dependencies for the crate
    * `models` module no-longer requires dependencies introduced by parser, like `bytes` for encoding
* decouple `oneio` from `parser` feature
    * `oneio` is no-longer a required dependency for the parser
    * users can now use `parser` feature without `oneio` (with `--no-default-features` specified)
        * to create a new parser, one needs to user `BgpkitParser::from_reader` function instead of `BgpkitParser::new`
    * downstream libraries that only utilize parser code (such as RIS Live parsing) no-longer have to depend on oneio

## v0.10.10 - 2024-08-05

### Highlights

* update `oneio` to v0.17.0
    * now users can set env var `ONEIO_ACCEPT_INVALID_CERTS=true` to disable certificate validation, useful in some
      environment where users do not manage certificates

## v0.10.9 - 2024-04-12

### BMP messages SDK improvements

* expose all pub structs and enums for BMP messages
    * this allows users to access struct definitions and operate on them directly
* added `Copy` to `BmpMsgType`, `BmpPeerType` and `BmpPerPeerHeader`, `PerPeerFlags`, `BmpPeerType`
* implemented `Default`, `PartialEq`, `Eq` and `Hash` for `BmpPerPeerHeader`
    * this allows users and compare and hash `BmpPerPeerHeader` structs
    * also implemented `.strip_timestamp()` to remove the timestamp from the `BmpPerPeerHeader` struct for cases where
      the timestamp is not needed
* rename `MessageBody` to `BmpMessageBody`
* derive `Clone`, `PartialEq` to `BmpMessage` and `MessageBody`
* added serialization/deserialization support for `BmpMessage` and `BmpMessageBody`

## v0.10.8 - 2024-04-05

### Highlights

* improve support for more BMP data types and better error
  handling ([#163](https://github.com/bgpkit/bgpkit-parser/pull/163))
    * added explicit enum `PeerDownReason`, `TerminationReason`, `PeerUpTlvType` instead of saving them as integers
    * added support for AFI-SAFI gauge for `StatisticsReport` message
        * this fixes issue [#162](https://github.com/bgpkit/bgpkit-parser/pull/162)
    * added `UnknownTlvType` and `UnknownTlvValue` errors for parsing BMP TLV records
    * added `Clone` and `PartialEq` derives to most of the BMP message structs

## v0.10.7 - 2024-03-30

### Highlights

* improve end-of-RIB marker detection ([#161](https://github.com/bgpkit/bgpkit-parser/pull/161))

## v0.10.6 - 2024-03-30

### Bug fix

* fixed an code panic issue where malformed RIB dump entry with non-existing peer ID causes a panic
    * also removed a number of unwraps in the code to handle errors more gracefully
    * see issue [#157](https://github.com/bgpkit/bgpkit-parser/issues/158) for details

## v0.10.5 - 2024-03-26

### Highlights

* by default handles only `gzip` and `bzip2` files
    * to support `xz` and `lz` files, use the optional feature `xz` and `lz`

## v0.10.4 - 2024-03-20

### Hot fix

* update `oneio` to `v0.16.4`
    * add `http2` and `charset` feature flag to `reqwest`

## v0.10.3 - 2024-03-20

### Highlights

* fixed an panic issue when sometimes merging AS path segments of 4-byte ASN path and 2-byte ASN path
    * see issue [#156](https://github.com/bgpkit/bgpkit-parser/issues/156) for details
* update `oneio` to `v0.16.3`
    * gzip decompression depends on `flate2`'s `rust-backend` feature instead of `zlib-ng` which requires `cmake` to
      build

## v0.10.2 - 2024-03-06

### Highlights

* added new `ip_version` filter type with values of `ipv4` or `ipv6`
    * library users can use this filter to filter BGP messages by IP version
    * CLI users can specify `-4` or `-6` to filter BGP messages by IP version
* add new dependency security checkups using `cargo audit`
    * all new releases will need to pass `cargo audit` checks before being published
    * weekly `cargo audit` checks added to the CI pipeline

## v0.10.1 - 2024-02-23

### Highlights

* updating `oneio` to `v0.16.2`
    * switching to `flate2` with `zlib-ng` for handling `gzip` files, which is significantly faster than the default
      pure-Rust implementation

## v0.10.0 - 2024-02-12

Version 0.10.0 is a major release with a lot of changes and improvements.

### Highlights

#### MRT Encoding

`bgpkit-parser` now supports encoding MRT messages. The following MRT message types are supported:

- TableDumpV1
- TableDumpV2
- BGP4MP
  It also supports encoding BMP messages into MRT files.

Example of writing BgpElems into a file RIB dump file:

```rust
let mut encoder = bgpkit_parser::encoder::MrtRibEncoder::new();
for elem in parser {
encoder.process_elem( & elem);
}
let mut writer = oneio::get_writer("filtered.rib.gz").unwrap();
writer.write_all(encoder.export_bytes().as_ref()).unwrap();
drop(writer);
```

Another example of writing `BgpElem` to BGP updates bytes:

```rust
let mut encoder = bgpkit_parser::encoder::MrtUpdatesEncoder::new();
let mut elem = BgpElem::default ();
elem.peer_ip = IpAddr::V4("10.0.0.1".parse().unwrap());
elem.peer_asn = Asn::from(65000);
elem.prefix.prefix = "10.250.0.0/24".parse().unwrap();
encoder.process_elem( & elem);
elem.prefix.prefix = "10.251.0.0/24".parse().unwrap();
encoder.process_elem( & elem);
let bytes = encoder.export_bytes();

let mut cursor = Cursor::new(bytes.clone());
while cursor.has_remaining() {
let parsed = parse_mrt_record( & mut cursor).unwrap();
dbg ! ( & parsed);
}
```

See `encoder` module for more details.

#### Better developer experiences

- added several utility functions to `BgpElem`
    - `.is_announcement()`: check if the BGP element is an announcement
    - `.get_as_path_opt()`: get the AS path if it exists and no AS set or confederated segments
    - `.get_origin_asn_opt()`: get the origin ASN if it exists
- full `serde` serialization support
- add `BgpElem` to PSV (pipe-separated values) conversion
- improved time-related filters parsing
    - `ts_start` `start_ts` `ts_end` `end_ts` are all supported
- many quality of life improvements by [@jmeggitt](https://github.com/jmeggitt)
    - https://github.com/bgpkit/bgpkit-parser/pull/122
    - https://github.com/bgpkit/bgpkit-parser/pull/123

#### Improved testing coverage

- `bgpkit-parser` code test coverage is now at 92%.
    - codecov.io coverage report is available at https://app.codecov.io/gh/bgpkit/bgpkit-parser

#### TLS backend choice

- by default, `bgpkit-parser` now uses `rustls` as the default TLS backend
    - `openssl` is still supported, but it is no longer the default
    - `openssl` support can be enabled by using the `native-tls` feature flag and set default features to `false`

### Added RFCs support

- [`RFC 4724: Graceful Restart Mechanism for BGP`][rfc4724]
- [`RFC 8671 Support for Adj-RIB-Out in the BGP Monitoring Protocol (BMP)`][rfc8671]
- [`RFC 9069: Support for Local RIB in the BGP Monitoring Protocol (BMP)`][rfc9069]
- the supported RFCs list is documented at https://github.com/bgpkit/bgpkit-parser?tab=readme-ov-file#rfcs-support

[rfc4724]: https://www.rfc-editor.org/rfc/rfc4724

[rfc8671]: https://www.rfc-editor.org/rfc/rfc8671

[rfc9069]: https://www.rfc-editor.org/rfc/rfc9069

### Fixes

- fixed a bug where when multiple `AsSequences` are present, only the first one is parsed
    - issue: https://github.com/bgpkit/bgpkit-parser/issues/140
- fixed a bug where the parser panics when messages are truncated
    - https://github.com/bgpkit/bgpkit-parser/issues/149

### Other changes

- Move pybgpkit to its own repository at https://github.com/bgpkit/pybgpkit
- CLI build feature changed from `build-binary` to `cli`
- add more ways to install compiled `bgpkit-parser` CLI
    - homebrew on macOS: `brew install bgpkit/tap/bgpkit-parser`
    - other platforms: `cargo binstall bgpkit-parser`

## v0.10.0-beta.3 - 2024-02-08

### Highlights

`Bytes::split_to` will panic if not enough bytes available.
We added multiple safety checks to make sure enough bytes are available before calling `.split_to()` function.
If not enough bytes available, it will send out a `TruncatedMsg` error.
The current iterator will catch the error and skip the remainder of the message.

### Breaking changes

- remove `IoNotEnoughBytes`, and use `TruncatedMsg` when not enough bytes available to read

### Other changes

- bump `bytes` crate version to `1.5.0`

## v0.10.0-beta.2 - 2024-01-29

### Highlights

- switch to `rustls` as default TLS backend and remove unnecessary build dependencies and feature flags
    - updated `oneio` to v0.16.0
    - remove `openssl` and `vendored-openssl` dependency and feature flag for building CLI binary
    - remove `ureq` dev-dependency

### Release process changes

- added `cargo binstall` support
- added SHA256 checksum to corresponding release binary files

## v0.10.0-beta.1 - 2024-01-03

* add TableDumpV2 support: https://github.com/bgpkit/bgpkit-parser/pull/146
* increase code test coverage to 92%: https://github.com/bgpkit/bgpkit-parser/pull/147
