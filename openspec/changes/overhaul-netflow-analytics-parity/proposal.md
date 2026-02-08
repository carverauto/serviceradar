# Change: Overhaul NetFlow Analytics UI and Enrichment for Akvorado Feature Parity

## Why

ServiceRadar's NetFlow analytics UI is functional but embedded as a tab within the observability page with basic D3 charts and limited interactivity. Akvorado (the open-source flow analytics tool we benchmarked) provides a purpose-built analytics experience: a dedicated Visualize page with configurable dimensions, 5 chart types (stacked area, 100% stacked, lines, grid, sankey), bidirectional traffic, previous period comparison, a rich filter expression editor, per-interface/per-exporter metadata, and application-level classification. We need to close this gap to give operators the same depth of visibility into network traffic while leveraging our SRQL query engine, TimescaleDB, and existing enrichment infrastructure as differentiators.

## What Changes

### UI Overhaul (Complete Rebuild of NetFlow Analytics)

- **Dedicated `/netflow` route** with left-panel options (time range, dimensions, filters, graph type, units, SRQL query) and right-panel visualization + data table. No longer embedded as a tab in `/observability`.
- **5 chart types** rendered in D3 (consistent with rest of platform): stacked area, 100% stacked area, line series, grid (multi-panel), and sankey diagram.
- **Bidirectional traffic mode** showing forward + reverse traffic on the same chart with dual Y-axes.
- **Previous period comparison** overlaying prior time window data on current chart (auto-detected: hour/day/week/month/year).
- **Dimension selector** with drag-and-drop ordering, IP truncation (CIDR /8, /16, /24 aggregation), configurable top-N limit (1-50), and color-coded dimension categories (Exporter=blue, Src=green, Dst=purple, Interface=cyan).
- **SRQL-powered filter bar** with syntax highlighting, auto-completion from SRQL catalog, real-time validation, and saved filter management.
- **Data table** below charts showing raw dimension breakdowns with statistics: average, min, max, 95th percentile per series.
- **Units selector**: bits/sec, packets/sec, bytes/sec, percentage of interface capacity (requires interface speed).
- **Homepage dashboard** with configurable top-N pie/donut charts (by AS, country, exporter, protocol, port, application), flow rate gauge, exporter health list, and mini traffic graph.
- **Shareable URL state** via compressed serialization (full query state encoded in URL for bookmarkable/shareable views).
- **Brush selection** on time-series charts to zoom into a time range.
- **Legend interactivity** with click-to-toggle series visibility.

### Enrichment & Data Model

- **Interface name resolution** joining `input_snmp`/`output_snmp` indices from flows with our existing interface inventory (device_id + if_index lookup) to surface `in_if_name`, `out_if_name`, `in_if_speed`, `out_if_speed`, `in_if_description`, `out_if_description` in SRQL queries and visualizations.
- **Exporter metadata enrichment** mapping `sampler_address` to device inventory for exporter name, site, role, and group.
- **Deep application classification** beyond port mapping: well-known IP range databases (Netflix, Google/YouTube, Microsoft, gaming services, CDN providers), configurable IP-to-application rules, and SNI-based classification when TLS ClientHello data is available from flow exporters.
- **AlienVault OTX integration** as a threat intelligence feed source alongside existing generic CIDR feed support.
- **Interface boundary classification** (`external`/`internal`) derived from our existing interface classification rules, surfaced as SRQL filter/group-by dimensions.
- **Additional flow schema fields** for parity: `etype` (IPv4/IPv6), `tcp_flags` (decoded), `ip_tos`/`dscp`, `next_hop`, `flow_direction` (ingress/egress from exporter perspective), `src_vlan`/`dst_vlan`, `sampling_rate`.
- **SRQL dimension extensions**: `in_if_name`, `out_if_name`, `exporter_name`, `in_if_boundary`, `out_if_boundary`, `etype`, `src_net_prefix`, `dst_net_prefix` as filter and group-by dimensions.
- **Network dictionary system** for admin-defined IP range → metadata mappings (similar to akvorado's custom dictionaries), enabling arbitrary labels like network zone, cost center, or business unit on flow data.

### Performance & Storage

- **TimescaleDB continuous aggregates** at multiple resolutions (5min, 1h, 1d) with automatic data tiering and retention policies. SRQL auto-selects the optimal resolution based on query time range.
- **Materialized exporter/interface view** that maintains a live inventory of active exporters and their interfaces from flow data (akin to akvorado's `exporters` table).

## Impact

- Affected specs: `build-web-ui`, `srql`, `observability-signals`
- Affected code:
  - `web-ng/` - New LiveView pages, D3 hooks, SRQL catalog extensions
  - `rust/srql/` - New dimensions, aggregation modes, resolution auto-selection
  - `elixir/serviceradar_core/` - New Ash resources, enrichment workers, Oban jobs
  - Database migrations for new schema fields, continuous aggregates, network dictionaries
- **BREAKING**: The NetFlows tab in `/observability` will be replaced by the dedicated `/netflow` route. Bookmarks to the old tab path should redirect.
- Dependencies: Existing `add-netflow-observability-dashboard`, `add-netflow-advanced-visualizations`, `add-netflow-application-analytics`, and `add-interface-classification` changes provide the foundation. This change builds on top of them.
