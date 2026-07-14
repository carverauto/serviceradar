# Examples

This directory contains runnable examples for bgpkit_parser. They demonstrate basic usage, filtering, batch processing with BGPKIT Broker, real_time streaming, attribute and metadata inspection, error handling, and more. Each entry below links directly to the source so you can browse it on GitHub.

## Quickstart and Iteration
- [parse_single_file.rs](parse_single_file.rs) — Download and iterate over a single RouteViews updates file, logging each BGP element (BgpElem).
- [parse_single_file_parallel.rs](parse_single_file_parallel.rs) — Parse a single compressed RIB in parallel using a raw iterator + worker pool. Downloads to current directory if remote, counts elems, and compares timing with a sequential run. Tunables via env vars: BATCH_SIZE, WORKERS, CHAN_CAP, ELEM_IN_WORKERS, QUIET_ERRORS.
- [display_elems.rs](display_elems.rs) — Print selected fields from each BGP element in a compact, pipe-delimited format.
- [count_elems.rs](count_elems.rs) — Count the total number of BGP elements in a given file.
- [records_iter.rs](records_iter.rs) — Iterate over raw MRT records and inspect/update messages; includes an example of detecting the Only_To_Customer (OTC) attribute.
- [update_messages_iter.rs](update_messages_iter.rs) — Iterate over BGP announcements using the intermediate MrtUpdate representation; compares performance with BgpElem iteration and works with both UPDATES files and RIB dumps.
- [scan_mrt.rs](scan_mrt.rs) — CLI-style scanner that quickly walks an MRT file, counting raw records, parsed records, or elements without processing them.

## Filtering and Policy Examples
- [filters.rs](filters.rs) — Parse an MRT file and filter by a specific prefix (e.g., 211.98.251.0/24), logging matching announcements.
- [filter_export_rib.rs](filter_export_rib.rs) — Filter the content of a RIB by origin ASN and re_encode/export to a new RIB file.
- [find_as_set_messages.rs](find_as_set_messages.rs) — Find announcements containing AS_SET/CONFED_SET segments in AS paths across RIBs retrieved via BGPKIT Broker.

## Batch and Broker Workflows
- [parse_files_from_broker.rs](parse_files_from_broker.rs) — Use BGPKIT Broker to find data files for a time range and parse them, including a simple origin_ASN filter example.
- [parse_files_from_broker_parallel.rs](parse_files_from_broker_parallel.rs) — Query BGPKIT Broker then parse multiple files in parallel using Rayon, reporting the total message count.
- [cache_reading.rs](cache_reading.rs) — Use the parser’s on_disk cache to avoid re_downloading the same remote files when iterating over time ranges.
- [mrt_filter_archiver.rs](mrt_filter_archiver.rs) — Apply filters while reading updates and archive the filtered stream into a new MRT file; re_parse to verify the output.

## Real_time Streams (RIS Live, RouteViews Kafka, BMP)
- [real_time_ris_live_websocket.rs](real_time_ris_live_websocket.rs) — Connect to RIPE RIS Live over WebSocket (tungstenite), subscribe to a collector, parse, and print elements.
- [real_time_ris_live_websocket_async.rs](real_time_ris_live_websocket_async.rs) — Async tokio+tungstenite version of the RIS Live WebSocket subscriber.
- [real_time_routeviews_kafka_openbmp.rs](real_time_routeviews_kafka_openbmp.rs) — Consume RouteViews Kafka topics (OpenBMP format), parse BMP messages, and print derived elements.
- [real_time_routeviews_kafka_to_mrt.rs](real_time_routeviews_kafka_to_mrt.rs) — Consume RouteViews Kafka BMP messages and archive them into an MRT file for later analysis.
- [bmp_listener.rs](bmp_listener.rs) — Minimal TCP BMP listener that parses incoming BMP Route Monitoring messages and logs them.

## Attributes and Metadata
- [extended_communities.rs](extended_communities.rs) — Print BGP elements that carry extended, large, or IPv6_extended communities.
- [deprecated_attributes.rs](deprecated_attributes.rs) — Identify announcements that include deprecated attributes (e.g., attribute 28, BGP Entropy Label Capability) and print them in JSON.
- [peer_index_table.rs](peer_index_table.rs) — Read a Table Dump v2 RIB and pretty_print the Peer Index Table in JSON.
- [only_to_customer.rs](only_to_customer.rs) — Find and display paths bearing the Only_To_Customer (OTC, RFC 9234) attribute.

## Error Handling and Robustness
- [fallible_parsing.rs](fallible_parsing.rs) — Demonstrate fallible record/element iterators that let you handle parse errors explicitly while continuing to process.

## Debugging and Analysis
- [mrt_debug.rs](mrt_debug.rs) — Demonstrate MRT debugging features: debug display for MRT records, raw byte export, and the new `Display` implementation.
- [extract_problematic_records.rs](extract_problematic_records.rs) — Find and export MRT records that fail to parse for further analysis with other tools.

## RPKI RTR Protocol
- [rtr_client.rs](rtr_client.rs) — Connect to an RTR server (RFC 6810/8210), fetch ROAs, and validate a route announcement (1.1.1.0/24 -> AS13335). Demonstrates RTR PDU parsing and encoding.

## Local-only and Misc
- [local_only/src/main.rs](local_only/src/main.rs) — Minimal example that reads a local updates.bz2 file; intended for local experimentation (not network fetching).
