# Change: NetFlow Analytics Parity Program (Akvorado Benchmark, SRQL-Driven)

## Why

ServiceRadar's NetFlow analytics UI is functional but embedded as a tab within the observability page with basic D3 charts and limited interactivity. Akvorado (the open-source flow analytics tool we benchmarked) provides a purpose-built analytics experience: a dedicated Visualize page with configurable dimensions, 5 chart types (stacked area, 100% stacked, lines, grid, sankey), bidirectional traffic, previous period comparison, a rich filter expression editor, per-interface/per-exporter metadata, and application-level classification. We need to close this gap to give operators the same depth of visibility into network traffic while leveraging our SRQL query engine, TimescaleDB, and existing enrichment infrastructure as differentiators.

## What Changes

This change is a program-level proposal that defines the target end-state and the delivery plan. Implementation will be split across multiple smaller OpenSpec changes so we can ship incrementally, validate in demo, and avoid an all-or-nothing rewrite.

### Guiding Constraints
- All NetFlow charts and widgets SHALL be driven by SRQL queries (no Ecto queries for chart data).
- Database schema changes SHALL be done via Elixir migrations under `elixir/serviceradar_core/priv/repo/migrations/` in the `platform` schema.
- We keep D3-based visualization hooks for consistency with existing `web-ng` patterns.

## v1 Scope (Must-Haves)

This is the minimum operator-visible parity slice we consider "usable" for v1:
- Dedicated `/netflow` Visualize page (left options panel + right visualization surface).
- SRQL-only chart data paths (no Ecto-based chart queries).
- 5 chart types: stacked area, 100% stacked, lines, grid, sankey.
- Overlays: bidirectional and previous-period (where supported).
- Dimension/ranking controls needed to drive the above (at least 2 dimensions for Sankey).

## Deferred (Post-v1)

Explicitly not required for v1:
- OTX integration.
- Network dictionaries system.
- Deep application classification via SNI / external IP range imports.
- Per-user dashboard homepage and widget persistence.
- CAGGs + SRQL auto-resolution selection (unless performance forces it earlier).

## Current Status (2026-02-08)

Plan/proposal is valid (`openspec validate overhaul-netflow-analytics-parity --strict` passes) and child changes have been scaffolded, but demo still has functional gaps that must be closed before we can claim Phase B parity is complete:
- Sankey rendering/edges are not reliably present in demo windows with traffic.
- Geo heatmap click handling has a type mismatch (country ISO2 value being treated as an integer in DB query).
- SRQL builder cannot fully represent some valid flow queries (absolute time window + extra filters) without forcing “Replace query”.

### UI Overhaul (Delivered In Slices)

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

## Delivery Plan (Phased)

Phase boundaries are defined by operator-visible value and by minimizing cross-cutting schema work.

### Phase A: Visualize Page Skeleton + State Model
- Add `/netflow` LiveView with left options panel and right viz surface.
- Implement shareable URL state for visualize options (compressed).
- Reuse existing SRQL query execution paths and existing chart hooks where possible.

### Phase B: Chart Parity (D3 Hooks)
- Promote existing stacked area and sankey into a shared chart framework.
- Add 100% stacked, lines, and grid.
- Add consistent tooltips, legend toggles, and responsive layout.

### Phase C: Dimension System (Akvorado-like)
- Multi-dimension selection and ordering.
- IP truncation controls for IP dimensions.
- Top-N limit and `limitType` ranking modes.

### Phase D: Interface/Exporter Enrichment
- Add `platform.flow_interface_cache` + refresh worker and SRQL dimensions.
- Add units, including pct-of-capacity (depends on interface speed).

### Phase E: Scale And Rollups
- Expand flow CAGGs and implement SRQL auto-resolution selection.
- Validate query plans and performance.

### Phase F: Deep Enrichment And Admin Systems
- Application IP range DB + importer + SRQL 3-tier COALESCE.
- Network dictionaries + SRQL group-by.
- AlienVault OTX feed type and settings.

### Phase G: NetFlow Dashboard Homepage
- Widget grid with persisted per-user layout and top-N widgets.

## Proposed Change Breakdown (Work Items Become Separate Changes)

This program will be executed as smaller changes (IDs are proposed and can be adjusted):
- `add-netflow-visualize-page`
- `add-netflow-d3-chart-suite`
- `add-netflow-dimensions-and-ranking`
- `add-netflow-interface-exporter-cache`
- `add-netflow-units-and-capacity`
- `add-netflow-caggs-auto-resolution`
- `add-netflow-app-ip-ranges`
- `add-netflow-network-dictionaries`
- `add-netflow-otx-feed`
- `add-netflow-dashboard-home`
