## Context

ServiceRadar has a production NetFlow collector (`rust/netflow-collector/`) that ingests NetFlow V5/V9/IPFIX via UDP, converts packets to `FlowMessage` protobuf, and publishes to NATS JetStream. The Elixir web UI renders flows under a `/netflow` route with time-series, Sankey, and statistics views. The `FlowMessage` proto already includes `SFLOW_5 = 1` as a flow type enum, and the collector bundle generator lists sFlow as a supported protocol — indicating sFlow was always anticipated but never implemented.

sFlow v5 differs from NetFlow in that it uses packet sampling (raw headers + counters) rather than flow aggregation. The `flowparser-sflow` crate (v0.1.0) provides a stateless parser that returns `SflowDatagram` → `Vec<SflowSample>` → `Vec<FlowRecord>`, where flow records include `RawPacketHeader`, `SampledIpv4`, `SampledIpv6`, `ExtendedSwitch`, `ExtendedRouter`, and `ExtendedGateway`.

## Goals / Non-Goals

**Goals:**
- Ingest sFlow v5 datagrams and convert them to `FlowMessage` protobuf using the same schema as NetFlow
- Follow the same crate architecture as `netflow-collector` (config, listener, converter, publisher, metrics, error modules)
- Publish to a separate NATS subject (`flows.raw.sflow`) so downstream consumers can subscribe to specific or all flow types
- Rename the UI tab from "NetFlow" to "Flows" and update routes (`/netflow` → `/flows`) with redirects from old paths
- Add `"sflow"` as a supported collector type in the enrollment/bundle API

**Non-Goals:**
- Deep packet inspection of `RawPacketHeader` bytes (parse the raw header to extract L3/L4 fields) — defer to a later iteration; use `SampledIpv4`/`SampledIpv6` records for flow fields
- Counter sample ingestion (interface/VLAN/processor counters) — these are a different data model and belong in a separate observability signal
- Merging netflow-collector and sflow-collector into a single binary — keep them separate for independent scaling and deployment
- Refactoring existing NetFlow code or the Elixir visualization beyond the rename

## Decisions

### 1. Separate crate, not a fork of netflow-collector

**Decision**: Create `rust/sflow-collector/` as its own workspace member rather than adding sFlow parsing into the netflow-collector binary.

**Rationale**: NetFlow uses `netflow_parser` with stateful template caching (`AutoScopedParser`), pending flow buffers, and version-specific dispatch (V5/V9/IPFIX). sFlow is stateless — `SflowParser::parse_bytes()` returns complete results per datagram with no template tracking. Combining them would add unnecessary complexity. Separate binaries also allow independent scaling — sFlow and NetFlow typically run on different ports (6343 vs 2055) and may have very different traffic volumes.

**Alternative considered**: Adding an `--sflow` mode flag to netflow-collector. Rejected because the parser interfaces are fundamentally different and would require complex branching in the listener.

### 2. flowparser-sflow crate for parsing

**Decision**: Use `flowparser-sflow = "0.1"` for sFlow v5 datagram parsing.

**Rationale**: It's a well-structured Rust crate with a clean API, serde support, DoS protection (`max_samples`), and covers the sFlow v5 spec including flow samples, counter samples, and extended records. The API is simple: `SflowParser::default().parse_bytes(&data)`.

### 3. Converter strategy — SampledIpv4/IPv6 first, RawPacketHeader deferred

**Decision**: Map `SampledIpv4` and `SampledIpv6` flow records directly to `FlowMessage` fields. For `RawPacketHeader`, set only `bytes` (from `frame_length`) and `etype` (from `header_protocol`) without parsing the raw header bytes. Enrich with `ExtendedSwitch` (VLANs), `ExtendedRouter` (next hop, prefix lengths), and `ExtendedGateway` (AS path, BGP communities).

**Rationale**: `SampledIpv4`/`SampledIpv6` provide src/dst IP, ports, protocol, TCP flags, and ToS — covering the most common flow analysis dimensions. Parsing raw headers (Ethernet → IP → TCP/UDP) from `RawPacketHeader.header` bytes adds complexity and can be added later. Most sFlow agents send both `RawPacketHeader` and `SampledIpv4`/`SampledIpv6` in the same flow sample, so we'll get good coverage.

**Field mapping:**

| FlowMessage field | sFlow source |
|---|---|
| `type` | `SFLOW_5` |
| `time_received_ns` | System clock at recv |
| `sequence_num` | `datagram.sequence_number` |
| `sampling_rate` | `flow_sample.sampling_rate` |
| `sampler_address` | `datagram.agent_address` |
| `bytes` | `SampledIpv4.length` or `RawPacketHeader.frame_length` |
| `packets` | `1` (sFlow samples individual packets) |
| `src_addr` / `dst_addr` | `SampledIpv4.src_ip` / `dst_ip` or `SampledIpv6` equivalents |
| `proto` | `SampledIpv4.protocol` |
| `src_port` / `dst_port` | `SampledIpv4.src_port` / `dst_port` |
| `tcp_flags` | `SampledIpv4.tcp_flags` |
| `ip_tos` | `SampledIpv4.tos` |
| `in_if` / `out_if` | `flow_sample.input` / `output` |
| `src_vlan` / `dst_vlan` | `ExtendedSwitch.src_vlan` / `dst_vlan` |
| `next_hop` | `ExtendedRouter.next_hop` |
| `src_net` / `dst_net` | `ExtendedRouter.src_mask_len` / `dst_mask_len` |
| `src_as` / `dst_as` | `ExtendedGateway.src_as` / `as_number` |
| `as_path` | `ExtendedGateway.as_path_segments` (flattened) |
| `bgp_communities` | `ExtendedGateway.communities` |
| `bgp_next_hop` | `ExtendedGateway.next_hop` |
| `etype` | `0x0800` (IPv4) or `0x86DD` (IPv6) based on record type |

### 4. Config structure — mirror netflow-collector minus template fields

**Decision**: Reuse the same config shape (listen_addr, buffer_size, nats_url, stream_name, subject, channel_size, batch_size, security, metrics_addr) but omit `max_templates`, `max_template_fields`, and `pending_flows` since sFlow is stateless. Add `max_samples_per_datagram` for DoS protection (maps to `SflowParserBuilder::with_max_samples`).

**Default listen port**: `0.0.0.0:6343` (IANA-assigned sFlow port).

### 5. NATS subject — separate from NetFlow

**Decision**: Publish to `flows.raw.sflow` (default subject), parallel to `flows.raw.netflow`.

**Rationale**: Keeps the data streams independent for filtering, rate limiting, and debugging. Downstream consumers that want all flows can subscribe to `flows.raw.>` or configure stream subjects to include both. The Elixir backend already handles flow type differentiation via the `FlowMessage.type` enum.

### 6. UI rename — "NetFlow" → "Flows"

**Decision**: Rename the tab label, route paths, settings pages, and SRQL catalog entry. Add HTTP redirects from `/netflow` → `/flows` and `/settings/netflows` → `/settings/flows`.

**Scope of rename:**
- Route: `/netflow` → `/flows`, `/settings/netflows` → `/settings/flows`
- Tab label: `"NetFlow"` → `"Flows"` in `log_live/index.ex` and SRQL catalog
- Panel title helper: `panel_title("netflows")` → `panel_title("flows")`
- LiveView modules: Keep existing module names (`NetflowLive.Visualize`, etc.) to minimize churn — only rename user-facing strings
- Old route redirects via `get("/netflow", PageController, :redirect_to_flows)` and similar

**Alternative considered**: Creating separate `/sflow` and `/netflow` tabs. Rejected because the underlying data model is identical (`FlowMessage`) and users will want a unified view. The `type` field allows filtering by protocol when needed.

## Risks / Trade-offs

- **[flowparser-sflow v0.1.0 maturity]** → The crate is at v0.1.0 and may have parsing edge cases. Mitigated by: DoS protection via `max_samples`, error logging for parse failures, and the stateless design means no state corruption risk. We can pin and upgrade as the crate matures.

- **[RawPacketHeader data loss]** → Not parsing raw headers means we miss flow fields when agents only send `RawPacketHeader` without `SampledIpv4`/`SampledIpv6`. Mitigated by: Most sFlow agents include both record types. We log a warning when a flow sample contains only raw headers and no typed IP records.

- **[Breaking URL change]** → Renaming `/netflow` to `/flows` breaks bookmarks and external links. Mitigated by: HTTP 301 redirects from old paths, preserving query parameters.

- **[Counter samples ignored]** → sFlow counter data (interface utilization, error rates) is discarded. This is acceptable for the flow observability use case — counter data belongs in a separate metrics pipeline.

## Open Questions

- Should the Elixir NATS subscriber for flows be updated to subscribe to `flows.raw.>` (wildcard) or explicitly list both `flows.raw.netflow` and `flows.raw.sflow`? Wildcard is simpler but may pick up unexpected subjects.
