# BGPKIT Parser

*This readme is generated from the library's doc comments using [cargo-readme](https://github.com/livioribeiro/cargo-readme). Please refer to the Rust docs website for the [full documentation](https://docs.rs/bgpkit-parser/latest/bgpkit_parser/)*

[![Build](https://github.com/bgpkit/bgpkit-parser/actions/workflows/build.yml/badge.svg)](https://github.com/bgpkit/bgpkit-parser/actions/workflows/build.yml)
[![Crates.io](https://img.shields.io/crates/v/bgpkit-parser)](https://crates.io/crates/bgpkit-parser)
[![Docs.rs](https://docs.rs/bgpkit-parser/badge.svg)](https://docs.rs/bgpkit-parser)
[![License](https://img.shields.io/crates/l/bgpkit-parser)](https://raw.githubusercontent.com/bgpkit/bgpkit-parser/master/LICENSE)
[![Discord](https://img.shields.io/discord/919618842613927977?label=Discord&style=plastic)](https://discord.gg/XDaAtZsz6b)
[![codecov](https://codecov.io/gh/bgpkit/bgpkit-parser/graph/badge.svg?token=WGT72575FR)](https://codecov.io/gh/bgpkit/bgpkit-parser)

BGPKIT Parser aims to provide the most ergonomic MRT/BGP/BMP message parsing Rust API.

BGPKIT Parser has the following features:
- **performant**: comparable to C-based implementations like `bgpdump` or `bgpreader`.
- **actively maintained**: we consistently introduce feature updates and bug fixes, and support most of the relevant BGP RFCs.
- **ergonomic API**: a three-line for loop can already get you started.
- **battery-included**: ready to handle remote or local, bzip2 or gz data files out of the box

## Getting Started

Add `bgpkit-parser` to your `Cargo.toml`.

Parse a BGP MRT file in three lines:

```rust
use bgpkit_parser::BgpkitParser;

for elem in BgpkitParser::new("http://archive.routeviews.org/route-views4/bgpdata/2022.01/UPDATES/updates.20220101.0000.bz2").unwrap() {
    println!("{}", elem);
}
```

## Examples

The examples below are organized by complexity. For complete runnable examples, check out the [examples folder](https://github.com/bgpkit/bgpkit-parser/tree/main/examples).

### Basic Examples

#### Parsing a Single MRT File

Let's say we want to print out all the BGP announcements/withdrawal from a single MRT file, either located remotely or locally.
Here is an example that does so.

```rust
use bgpkit_parser::BgpkitParser;
let parser = BgpkitParser::new("http://archive.routeviews.org/bgpdata/2021.10/UPDATES/updates.20211001.0000.bz2").unwrap();
for elem in parser {
    println!("{}", elem)
}
```

Yes, it is this simple!

#### Counting BGP Messages

You can use iterator methods for quick analysis. For example, counting the number of announcements/withdrawals in a file:

```rust
use bgpkit_parser::BgpkitParser;
let url = "http://archive.routeviews.org/bgpdata/2021.10/UPDATES/updates.20211001.0000.bz2";
let count = BgpkitParser::new(url).unwrap().into_iter().count();
println!("total: {}", count);
```

Output:
```
total: 255849
```

### Intermediate Examples

#### Filtering BGP Messages

BGPKIT Parser has a built-in [Filter] mechanism to efficiently filter messages. Add filters when creating the parser to only process matching [BgpElem]s.

**Available filter types**: See the [Filter] enum documentation for all options.

```rust
use bgpkit_parser::BgpkitParser;

/// Filter by IP prefix
let parser = BgpkitParser::new("http://archive.routeviews.org/bgpdata/2021.10/UPDATES/updates.20211001.0000.bz2").unwrap()
    .add_filter("prefix", "211.98.251.0/24").unwrap();

for elem in parser {
    println!("{}", elem);
}
```

**Common filters**:
- `prefix`: Match a specific IP prefix
- `origin_asn`: Match origin AS number
- `peer_asn`: Match peer AS number
- `peer_ip`: Match peer IP address
- `elem_type`: Filter by announcement (`a`) or withdrawal (`w`)
- `as_path`: Match AS path with regex

**Negative filters**: Most filters support negation by prefixing the filter type with `!`. For example:
- `!origin_asn`: Match elements where origin AS is NOT the specified value
- `!prefix`: Match elements where prefix is NOT the specified value
- `!peer_ip`: Match elements where peer IP is NOT the specified value

**Note**: Timestamp filters (`ts_start`, `ts_end`) do not support negation.

```rust
use bgpkit_parser::BgpkitParser;

// Filter out all elements from AS 13335 (get everything EXCEPT AS 13335)
let parser = BgpkitParser::new("http://archive.routeviews.org/bgpdata/2021.10/UPDATES/updates.20211001.0000.bz2").unwrap()
    .add_filter("!origin_asn", "13335").unwrap();

for elem in parser {
    println!("{}", elem);
}
```

#### Parsing Multiple MRT Files with BGPKIT Broker

[BGPKIT Broker][broker-repo] library provides search API for all RouteViews and RIPE RIS MRT data files. Using the
broker's Rust API ([`bgpkit-broker`][broker-crates-io]), we can easily compile a list of MRT files that we are interested
in for any time period and any data type (`update` or `rib`). This allows users to gather information without needing to
know about the locations of specific data files.

[broker-repo]: https://github.com/bgpkit/bgpkit-broker
[broker-crates-io]: https://crates.io/crates/bgpkit-broker

The example below shows a relatively more interesting example that does the following:
- find all BGP archive data created on time 1634693400
- filter to only BGP updates files
- find all announcements originated from AS13335
- print out the total count of the announcements

```rust
use bgpkit_parser::{BgpkitParser, BgpElem};

let broker = bgpkit_broker::BgpkitBroker::new()
    .ts_start("1634693400")
    .ts_end("1634693400")
    .page(1);

for item in broker.into_iter().take(2) {
    log::info!("downloading updates file: {}", &item.url);
    let parser = BgpkitParser::new(item.url.as_str()).unwrap();

    log::info!("parsing updates file");
    // iterating through the parser. the iterator returns `BgpElem` one at a time.
    let elems = parser
        .into_elem_iter()
        .filter_map(|elem| {
            if let Some(origins) = &elem.origin_asns {
                if origins.contains(&13335.into()) {
                    Some(elem)
                } else {
                    None
                }
            } else {
                None
            }
        })
        .collect::<Vec<BgpElem>>();
    log::info!("{} elems matches", elems.len());
}
```

#### Error Handling

BGPKIT Parser returns `Result` types for operations that may fail. Here are common scenarios and how to handle them:

**Handling Parser Creation Errors**

```rust
use bgpkit_parser::BgpkitParser;

// The URL might be invalid or unreachable
match BgpkitParser::new("http://example.com/data.mrt.bz2") {
    Ok(parser) => {
        for elem in parser {
            println!("{}", elem);
        }
    }
    Err(e) => {
        eprintln!("Failed to create parser: {}", e);
        // Common causes:
        // - Invalid URL or file path
        // - Network connection issues
        // - Unsupported compression format
    }
}
```

**Handling Filter Errors**

```rust
use bgpkit_parser::BgpkitParser;

let mut parser = BgpkitParser::new("http://example.com/data.mrt.bz2").unwrap();

// Filter addition can fail with invalid input
match parser.add_filter("prefix", "invalid-prefix") {
    Ok(_) => println!("Filter added successfully"),
    Err(e) => {
        eprintln!("Invalid filter: {}", e);
        // Common causes:
        // - Invalid IP prefix format
        // - Invalid AS number
        // - Unknown filter type
    }
}
```

**Robust Production Code**

```rust
use bgpkit_parser::BgpkitParser;

fn process_mrt_file(url: &str) -> Result<usize, Box<dyn std::error::Error>> {
    let parser = BgpkitParser::new(url)?
        .add_filter("origin_asn", "13335")?;

    let mut count = 0;
    for elem in parser {
        // Process element
        count += 1;
    }

    Ok(count)
}

// Usage
match process_mrt_file("http://example.com/updates.bz2") {
    Ok(count) => println!("Processed {} elements", count),
    Err(e) => eprintln!("Error: {}", e),
}
```

### Advanced Examples

#### Parsing Real-time Data Streams

BGPKIT Parser provides parsing for real-time data streams, including [RIS-Live][ris-live-url]
and [BMP][bmp-rfc]/[OpenBMP][openbmp-url] messages.

**Parsing Messages From RIS-Live**

Here is an example of handling RIS-Live message streams. After connecting to the websocket server,
we need to subscribe to a specific data stream. In this example, we subscribe to the data stream
from on collector (`rrc21`). We can then loop and read messages from the websocket.

```rust
use bgpkit_parser::parse_ris_live_message;
use serde_json::json;
use tungstenite::{connect, Message};

const RIS_LIVE_URL: &str = "ws://ris-live.ripe.net/v1/ws/?client=rust-bgpkit-parser";

/// This is an example of subscribing to RIS-Live's streaming data from one host (`rrc21`).
///
/// For more RIS-Live details, check out their documentation at https://ris-live.ripe.net/manual/
fn main() {
    // connect to RIPE RIS Live websocket server
    let (mut socket, _response) =
        connect(RIS_LIVE_URL)
            .expect("Can't connect to RIS Live websocket server");

    // subscribe to messages from one collector
    let msg = json!({"type": "ris_subscribe", "data": {"host": "rrc21"}}).to_string();
    socket.send(Message::Text(msg.into())).unwrap();

    loop {
        let msg = socket.read().expect("Error reading message").to_string();
        if let Ok(elems) = parse_ris_live_message(msg.as_str()) {
            for elem in elems {
                println!("{}", elem);
            }
        }
    }
}
```

**Parsing OpenBMP Messages From RouteViews Kafka Stream**

[RouteViews](http://www.routeviews.org/routeviews/) provides a real-time Kafka stream of the OpenBMP
data received from their collectors. Below is a partial example of how we handle the raw bytes
received from the Kafka stream. For full examples, check out the [examples folder on GitHub](https://github.com/bgpkit/bgpkit-parser/tree/main/examples).

```rust
use bgpkit_parser::parser::bmp::messages::*;
use bgpkit_parser::parser::utils::*;
use bgpkit_parser::{Elementor, parse_openbmp_header, parse_bmp_msg};

let bytes = &m.value;
let mut data = Bytes::from(bytes.clone());
let header = parse_openbmp_header(&mut data).unwrap();
let bmp_msg = parse_bmp_msg(&mut data);
match bmp_msg {
    Ok(msg) => {
        let timestamp = header.timestamp;
        let per_peer_header = msg.per_peer_header.unwrap();
        match msg.message_body {
            BmpMessageBody::RouteMonitoring(m) => {
                for elem in Elementor::bgp_to_elems(
                    m.bgp_message,
                    timestamp,
                    &per_peer_header.peer_ip,
                    &per_peer_header.peer_asn
                )
                {
                    info!("{}", elem);
                }
            }
            _ => {}
        }
    }
    Err(_e) => {
        let hex = hex::encode(bytes);
        error!("{}", hex);
    }
}
```

[ris-live-url]: https://ris-live.ripe.net
[bmp-rfc]: https://datatracker.ietf.org/doc/html/rfc7854
[openbmp-url]: https://www.openbmp.org/

#### Encoding: Archiving Filtered MRT Records

The example will download one MRT file from RouteViews, filter out all the BGP messages that
are not originated from AS3356, and write the filtered MRT records to disk. Then it re-parses the
filtered MRT file and prints out the number of BGP messages.

```rust
use bgpkit_parser::Elementor;
use itertools::Itertools;
use std::io::Write;

let mut updates_encoder = bgpkit_parser::encoder::MrtUpdatesEncoder::new();

bgpkit_parser::BgpkitParser::new(
    "http://archive.routeviews.org/bgpdata/2023.10/UPDATES/updates.20231029.2015.bz2",
).unwrap()
    .add_filter("origin_asn", "3356").unwrap()
    .into_iter()
    .for_each(|elem| {
        updates_encoder.process_elem(&elem);
    });

let mut mrt_writer = oneio::get_writer("as3356_mrt.gz").unwrap();
mrt_writer.write_all(updates_encoder.export_bytes().as_ref()).unwrap();
drop(mrt_writer);
```

## FAQ & Troubleshooting

### Common Issues

#### Parser creation fails with "unsupported compression"
**Problem**: The file uses an unsupported compression format.

**Solution**: BGPKIT Parser natively supports `.bz2` and `.gz` compression. For other formats, decompress the file first or use the [`oneio`](https://crates.io/crates/oneio) crate which supports additional formats.

#### Out of memory when parsing large files
**Problem**: Collecting all elements into a vector exhausts available memory.

**Solution**: Use streaming iteration instead of collecting:
```rust
// ❌ Don't do this for large files
let all_elems: Vec<_> = parser.into_iter().collect();

// ✅ Process iteratively
for elem in parser {
    // Process one element at a time
    process(elem);
}
```

#### Slow performance on network files
**Problem**: Remote file parsing is slower than expected.

**Solution**:
- Use the `--cache-dir` option in CLI to cache downloaded files
- In library code, download the file first with appropriate buffering
- Consider processing files in parallel if dealing with multiple files

#### Missing or incomplete BGP attributes
**Problem**: Some [BgpElem] fields are `None` when you expect values.

**Solution**: Not all BGP messages contain all attributes. Check the MRT format and BGP message type:
- Withdrawals typically don't have AS paths or communities
- Some collectors may not export certain attributes
- Use pattern matching to handle `Option` types properly

### Performance Tips

#### Use filters early
Apply filters during parser creation to avoid processing unwanted data:
```rust
// ✅ Efficient - filters during parsing
let parser = BgpkitParser::new(url)?
    .add_filter("prefix", "1.1.1.0/24")?;

// ❌ Less efficient - processes everything first
let filtered: Vec<_> = BgpkitParser::new(url)?
    .into_iter()
    .filter(|e| e.prefix.to_string() == "1.1.1.0/24")
    .collect();
```

#### Process multiple files in parallel
For bulk processing, use parallel iterators:
```rust
use rayon::prelude::*;

let files = vec!["file1.mrt.bz2", "file2.mrt.bz2", "file3.mrt.bz2"];
files.par_iter().for_each(|file| {
    let parser = BgpkitParser::new(file).unwrap();
    // Process each file in parallel
});
```

#### Choose the right data structure
- Use [MrtRecord] iteration for minimal memory overhead
- Use [MrtUpdate] for efficient batch processing without per-prefix attribute duplication
- Use [BgpElem] for easier per-prefix analysis
- See [Data Representation](#data-representation) for detailed comparison

## Command Line Tool

`bgpkit-parser` is bundled with a utility commandline tool `bgpkit-parser-cli`.

### Installation

#### Install compiled binaries

You can install the compiled `bgpkit-parser` CLI binaries with the following methods:
- **Homebrew** (macOS): `brew install bgpkit/tap/bgpkit-parser`
- [**Cargo binstall**](https://github.com/cargo-bins/cargo-binstall): `cargo binstall bgpkit-parser`

#### From source

You can install the tool by running
```bash
cargo install bgpkit-parser --features cli
```
or checkout this repository and run
```bash
cargo install --path . --features cli
```

### Usage

Run `bgpkit-parser --help` to see the full list of options.

```
MRT/BGP/BMP data processing library

Usage: bgpkit-parser [OPTIONS] <FILE>

Arguments:
  <FILE>  File path to a MRT file, local or remote

Options:
  -c, --cache-dir <CACHE_DIR>    Set the cache directory for caching remote files. Default behavior does not enable caching
      --json                     Output as JSON objects
      --psv                      Output as full PSV entries with header
      --pretty                   Pretty-print JSON output
  -e, --elems-count              Count BGP elems
  -r, --records-count            Count MRT records
  -o, --origin-asn <ORIGIN_ASN>  Filter by origin AS Number
  -f, --filter <FILTERS>         Generic filter expression (key=value or key!=value)
  -p, --prefix <PREFIX>          Filter by network prefix
  -4, --ipv4-only                Filter by IPv4 only
  -6, --ipv6-only                Filter by IPv6 only
  -s, --include-super            Include super-prefix when filtering
  -S, --include-sub              Include sub-prefix when filtering
  -j, --peer-ip <PEER_IP>        Filter by peer IP address
  -J, --peer-asn <PEER_ASN>      Filter by peer ASN
  -m, --elem-type <ELEM_TYPE>    Filter by elem type: announce (a) or withdraw (w)
  -t, --start-ts <START_TS>      Filter by start unix timestamp inclusive
  -T, --end-ts <END_TS>          Filter by end unix timestamp inclusive
  -a, --as-path <AS_PATH>        Filter by AS path regex string
  -h, --help                     Print help
  -V, --version                  Print version

```

### Common CLI Examples

#### Basic usage - Print all BGP messages
```bash
bgpkit-parser http://archive.routeviews.org/bgpdata/2021.10/UPDATES/updates.20211001.0000.bz2
```

#### Filter by origin AS
```bash
bgpkit-parser -o 13335 updates.20211001.0000.bz2
```

#### Filter by prefix
```bash
bgpkit-parser -p 1.1.1.0/24 updates.20211001.0000.bz2
```

#### Output as JSON
```bash
bgpkit-parser --json updates.20211001.0000.bz2 > output.json
```

#### Count elements efficiently
```bash
bgpkit-parser -e updates.20211001.0000.bz2
```

#### Cache remote files for faster repeated access
```bash
bgpkit-parser -c ~/.bgpkit-cache http://example.com/updates.mrt.bz2
```

#### Combine filters
```bash
# IPv4 announcements from AS13335
bgpkit-parser -o 13335 -m a -4 updates.bz2
```

#### Negative filters (exclude matching elements)
```bash
# Exclude elements from AS 13335
bgpkit-parser --filter "origin_asn!=13335" updates.bz2

# Exclude a specific peer
bgpkit-parser --filter "peer_ip!=192.168.1.1" updates.bz2

# Combine positive and negative filters
bgpkit-parser -o 13335 --filter "peer_asn!=64496" updates.bz2
```

## Data Representation

BGPKIT Parser provides three ways to access parsed BGP data: [MrtRecord], [MrtUpdate], and [BgpElem]. Choose based on your needs:

```
┌──────────────────────────────────────────────┐
│                  MRT File                    │
│  (Binary format: bgp4mp, tabledumpv2, etc.)  │
└──────────────────────┬───────────────────────┘
                       │
                       ├──> Parser
                       │
         ┌──────────────┼────────────────┐
         │              │                │
         ▼              ▼                ▼
   [MrtRecord]    [MrtUpdate]      [BgpElem]
   (Low-level)   (Intermediate)   (High-level)
         │             │                │
         └─────────────┴────────────────┘
                       │
                       ▼
              Your Analysis Code
```

### [MrtRecord]: Low-level MRT Representation

[MrtRecord] preserves the complete, unmodified information from the MRT file. Use this when you need:
- **Raw MRT data access**: Direct access to all MRT fields
- **Format-specific details**: Peer index tables, geo-location data, etc.
- **Memory efficiency**: Minimal overhead, compact representation
- **Re-encoding**: Converting back to MRT format

See the [MrtRecord] documentation for the complete structure definition.

**Key components**:
- `common_header`: Contains timestamp, record type, and metadata
- `message`: The actual MRT message (TableDump, TableDumpV2, or Bgp4Mp)

**Iteration**: Use [`BgpkitParser::into_record_iter()`] to iterate over [MrtRecord]s.

### [MrtUpdate]: Intermediate Message-Level Representation

[MrtUpdate] provides access to BGP announcements without expanding them into individual per-prefix elements. This is a middle ground between [MrtRecord] and [BgpElem]. Use this when you need:
- **Efficient batch processing**: Avoid duplicating attributes across prefixes
- **Message-level analysis**: Work with UPDATE messages or RIB entries as units
- **Memory efficiency**: Shared attributes aren't cloned for each prefix

## RPKI RTR Protocol Support

BGPKIT Parser includes support for the RPKI-to-Router (RTR) protocol, enabling downstream
clients to communicate with RTR cache servers and fetch Route Origin Authorizations (ROAs).

### Overview

The RTR protocol is used to deliver validated RPKI data from a cache server to a router.
BGPKIT Parser provides:
- **PDU definitions**: All RTR protocol data structures for both v0 (RFC 6810) and v1 (RFC 8210)
- **Parsing**: Decode binary RTR PDUs into structured Rust types
- **Encoding**: Serialize RTR PDUs to binary format for sending to servers

**Note**: This library provides PDU parsing/encoding only. Transport (TCP, SSH, TLS) and
RPKI validation logic are out of scope and should be handled by downstream clients.

### Quick Example

```rust
use bgpkit_parser::models::rpki::rtr::*;
use bgpkit_parser::parser::rpki::rtr::{parse_rtr_pdu, RtrEncode};

// Create a Reset Query to request the full ROA database
let query = RtrResetQuery::new_v1();
let bytes = query.encode();

// Parse a PDU from bytes
let (pdu, consumed) = parse_rtr_pdu(&bytes).unwrap();
assert!(matches!(pdu, RtrPdu::ResetQuery(_)));
```

### Available PDU Types

| PDU Type | Direction | Description |
|----------|-----------|-------------|
| Serial Notify | Server → Client | Notifies client of new data |
| Serial Query | Client → Server | Requests incremental update |
| Reset Query | Client → Server | Requests full database |
| Cache Response | Server → Client | Begins data transfer |
| IPv4 Prefix | Server → Client | ROA for IPv4 prefix |
| IPv6 Prefix | Server → Client | ROA for IPv6 prefix |
| End of Data | Server → Client | Ends data transfer |
| Cache Reset | Server → Client | Cannot provide incremental update |
| Router Key | Server → Client | BGPsec key (v1 only) |
| Error Report | Bidirectional | Error notification |

### Building an RTR Client

See the [`rtr_client` example](https://github.com/bgpkit/bgpkit-parser/blob/main/examples/rtr_client.rs)
for a complete working example that:
1. Connects to an RTR server
2. Sends a Reset Query
3. Collects ROAs
4. Validates a route announcement (1.1.1.0/24 → AS13335)

```bash
cargo run --example rtr_client -- rtr.rpki.cloudflare.com 8282
```

**Supported message types** (via enum variants):
- `Bgp4MpUpdate`: BGP UPDATE messages from UPDATES files
- `TableDumpV2Entry`: RIB entries from TableDumpV2 RIB dumps
- `TableDumpMessage`: Legacy TableDump v1 messages

**Example**:
```rust
use bgpkit_parser::{BgpkitParser, MrtUpdate};

let parser = BgpkitParser::new("updates.mrt.bz2").unwrap();
for update in parser.into_update_iter() {
    match update {
        MrtUpdate::Bgp4MpUpdate(u) => {
            // One UPDATE message may contain multiple prefixes sharing attributes
            println!("Peer {} announced {} prefixes",
                u.peer_ip,
                u.message.announced_prefixes.len()
            );
        }
        MrtUpdate::TableDumpV2Entry(e) => {
            // One prefix with multiple RIB entries (one per peer)
            println!("Prefix {} seen by {} peers",
                e.prefix,
                e.rib_entries.len()
            );
        }
        MrtUpdate::TableDumpMessage(m) => {
            println!("Legacy table dump for {}", m.prefix);
        }
    }
}
```

**Iteration**: Use [`BgpkitParser::into_update_iter()`] to iterate over [MrtUpdate]s.

### [BgpElem]: High-level Per-Prefix Representation

[BgpElem] provides a simplified, per-prefix view of BGP data. Each [BgpElem] represents a single prefix announcement or withdrawal. Use this when you want:
- **Simple analysis**: Focus on prefixes without worrying about MRT format details
- **Format-agnostic processing**: Same structure regardless of MRT format
- **BGP attributes**: Easy access to AS path, communities, etc.

**Example transformation**:
```
MRT Record with 3 prefixes        →        3 BgpElem objects
┌────────────────────────┐              ┌──────────────────┐
│ BGP UPDATE Message     │              │ BgpElem          │
│ AS Path: 64512 64513   │  ────────>   │ prefix: P1       │
│ Prefixes:              │              │ as_path: 64512.. │
│   - P1: 10.0.0.0/24    │              └──────────────────┘
│   - P2: 10.0.1.0/24    │              ┌──────────────────┐
│   - P3: 10.0.2.0/24    │  ────────>   │ BgpElem          │
└────────────────────────┘              │ prefix: P2       │
                                        │ as_path: 64512.. │
                                        └──────────────────┘
                                        ┌──────────────────┐
                                        │ BgpElem          │
                            ────────>   │ prefix: P3       │
                                        │ as_path: 64512.. │
                                        └──────────────────┘
```

See the [BgpElem] documentation for the complete structure definition.

**Key fields**:
- `timestamp`: Unix timestamp of the BGP message
- `elem_type`: Announcement or withdrawal
- `peer_ip` / `peer_asn`: The BGP peer information
- `prefix`: The IP prefix being announced or withdrawn
- `as_path`: The AS path attribute (if present)
- `origin_asns`: Origin AS numbers extracted from AS path
- `communities`: BGP communities (standard, extended, and large)
- `next_hop`, `local_pref`, `med`: Other BGP attributes

**Iteration**: Use [`BgpkitParser::into_elem_iter()`] or default iteration to iterate over [BgpElem]s.

### Which One Should I Use?

| Use Case | Recommended | Why |
|----------|-------------|-----|
| Simple prefix analysis | [BgpElem] | Easy per-prefix access, format-agnostic |
| High-performance processing | [MrtUpdate] | Avoids attribute duplication overhead |
| Counting prefixes per UPDATE | [MrtUpdate] | Direct access to message structure |
| Re-encoding MRT data | [MrtRecord] | Preserves complete MRT structure |
| MRT format-specific details | [MrtRecord] | Access to peer index tables, geo-location, etc. |

**Memory trade-off**:
- [BgpElem] duplicates shared attributes (AS path, communities) for each prefix
- [MrtUpdate] keeps attributes shared within each message/entry
- [MrtRecord] has minimal overhead but requires more code to extract BGP data

## RFCs Support

BGPKIT Parser implements comprehensive BGP, MRT, BMP, and related protocol standards. All listed RFCs are fully supported.

**Request a feature**: If you need support for a specific RFC not listed here, please [submit an issue on GitHub](https://github.com/bgpkit/bgpkit-parser/issues).

### Core BGP Protocol

**Most commonly used**:
- [RFC 4271](https://datatracker.ietf.org/doc/html/rfc4271): A Border Gateway Protocol 4 (BGP-4) - Core protocol
- [RFC 2858](https://datatracker.ietf.org/doc/html/rfc2858): Multiprotocol Extensions for BGP-4 (IPv6 support)
- [RFC 6793](https://datatracker.ietf.org/doc/html/rfc6793): Four-Octet AS Number Space
- [RFC 7911](https://datatracker.ietf.org/doc/html/rfc7911): Advertisement of Multiple Paths (ADD-PATH)

**Additional BGP RFCs**:
- [RFC 2042](https://datatracker.ietf.org/doc/html/rfc2042): Registering New BGP Attribute Types
- [RFC 2918](https://datatracker.ietf.org/doc/html/rfc2918): Route Refresh Capability for BGP-4
- [RFC 3392](https://datatracker.ietf.org/doc/html/rfc3392): Capabilities Advertisement with BGP-4
- [RFC 4724](https://datatracker.ietf.org/doc/html/rfc4724): Graceful Restart Mechanism for BGP
- [RFC 4456](https://datatracker.ietf.org/doc/html/rfc4456): BGP Route Reflection
- [RFC 5065](https://datatracker.ietf.org/doc/html/rfc5065): Autonomous System Confederations for BGP
- [RFC 5492](https://datatracker.ietf.org/doc/html/rfc5492): Capabilities Advertisement with BGP-4
- [RFC 7606](https://datatracker.ietf.org/doc/html/rfc7606): Revised Error Handling for BGP UPDATE Messages
- [RFC 8654](https://datatracker.ietf.org/doc/html/rfc8654): Extended Message Support for BGP
- [RFC 8950](https://datatracker.ietf.org/doc/html/rfc8950): Advertising IPv4 NLRI with an IPv6 Next Hop
- [RFC 9072](https://datatracker.ietf.org/doc/html/rfc9072): Extended Optional Parameters Length for BGP OPEN Message
- [RFC 9234](https://datatracker.ietf.org/doc/html/rfc9234): Route Leak Prevention Using Roles in UPDATE and OPEN Messages

### MRT (Multi-Threaded Routing Toolkit)

- [RFC 6396](https://datatracker.ietf.org/doc/html/rfc6396): MRT Routing Information Export Format
- [RFC 6397](https://datatracker.ietf.org/doc/html/rfc6397): MRT BGP Routing Information Export Format with Geo-Location Extensions
- [RFC 8050](https://datatracker.ietf.org/doc/html/rfc8050): MRT Routing Information Export Format with BGP Additional Path Extensions

### BMP (BGP Monitoring Protocol)

- [RFC 7854](https://datatracker.ietf.org/doc/html/rfc7854): BGP Monitoring Protocol (BMP)
- [RFC 8671](https://datatracker.ietf.org/doc/html/rfc8671): Support for Adj-RIB-Out in BMP
- [RFC 9069](https://datatracker.ietf.org/doc/html/rfc9069): Support for Local RIB in BMP

### BGP Communities

Full support for standard, extended, and large communities:
- [RFC 1997](https://datatracker.ietf.org/doc/html/rfc1997): BGP Communities Attribute
- [RFC 4360](https://datatracker.ietf.org/doc/html/rfc4360): BGP Extended Communities Attribute
- [RFC 5668](https://datatracker.ietf.org/doc/html/rfc5668): 4-Octet AS Specific BGP Extended Community
- [RFC 5701](https://datatracker.ietf.org/doc/html/rfc5701): IPv6 Address Specific BGP Extended Community Attribute
- [RFC 7153](https://datatracker.ietf.org/doc/html/rfc7153): IANA Registries for BGP Extended Communities
- [RFC 8097](https://datatracker.ietf.org/doc/html/rfc8097): BGP Prefix Origin Validation State Extended Community
- [RFC 8092](https://datatracker.ietf.org/doc/html/rfc8092): BGP Large Communities

### RPKI-to-Router (RTR) Protocol

- [RFC 6810](https://datatracker.ietf.org/doc/html/rfc6810): The Resource Public Key Infrastructure (RPKI) to Router Protocol
- [RFC 8210](https://datatracker.ietf.org/doc/html/rfc8210): The Resource Public Key Infrastructure (RPKI) to Router Protocol, Version 1

### Advanced Features

**FlowSpec**:
- [RFC 8955](https://datatracker.ietf.org/doc/html/rfc8955): Dissemination of Flow Specification Rules
- [RFC 8956](https://datatracker.ietf.org/doc/html/rfc8956): Dissemination of Flow Specification Rules for IPv6
- [RFC 9117](https://datatracker.ietf.org/doc/html/rfc9117): Revised Validation Procedure for BGP Flow Specifications

**Tunnel Encapsulation**:
- [RFC 5640](https://datatracker.ietf.org/doc/html/rfc5640): Load-Balancing for Mesh Softwires
- [RFC 8365](https://datatracker.ietf.org/doc/html/rfc8365): Ethernet VPN (EVPN)
- [RFC 9012](https://datatracker.ietf.org/doc/html/rfc9012): BGP Tunnel Encapsulation Attribute

**Link-State (BGP-LS)**:
- [RFC 7752](https://datatracker.ietf.org/doc/html/rfc7752): North-Bound Distribution of Link-State and TE Information
- [RFC 8571](https://datatracker.ietf.org/doc/html/rfc8571): BGP-LS Advertisement of IGP TE Performance Metric Extensions
- [RFC 9085](https://datatracker.ietf.org/doc/html/rfc9085): BGP-LS Extensions for Segment Routing
- [RFC 9294](https://datatracker.ietf.org/doc/html/rfc9294): BGP-LS Advertisement of Application-Specific Link Attributes

## See Also

### Related BGPKIT Projects

- **[BGPKIT Broker](https://github.com/bgpkit/bgpkit-broker)**: Search and discover MRT data files from RouteViews and RIPE RIS
- **[BGPKIT API](https://data.bgpkit.com)**: RESTful API for MRT data file discovery
- **[Monocle](https://github.com/bgpkit/monocle)**: Real-time BGP monitoring and alerting
- **[BGPKIT Commons](https://github.com/bgpkit/bgpkit-commons)**: Common data structures and utilities

### Resources

- **[GitHub Repository](https://github.com/bgpkit/bgpkit-parser)**: Source code, examples, and issue tracking
- **[Documentation](https://docs.rs/bgpkit-parser)**: Full API documentation
- **[Changelog](https://github.com/bgpkit/bgpkit-parser/blob/main/CHANGELOG.md)**: Version history and release notes

### Community

- **Questions?** Open a [GitHub Discussion](https://github.com/bgpkit/bgpkit-parser/discussions)
- **Found a bug?** Submit a [GitHub Issue](https://github.com/bgpkit/bgpkit-parser/issues)


## License

MIT
