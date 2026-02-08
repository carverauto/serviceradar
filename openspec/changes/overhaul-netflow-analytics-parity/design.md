## Context

ServiceRadar's NetFlow analytics is currently a tab within the observability page. Akvorado provides a best-in-class flow analytics UI that we are using as the benchmark for feature parity. Our differentiators (SRQL, TimescaleDB, threat intel, rDNS, ipinfo) should be preserved and enhanced. We use D3 for charts (not ECharts as akvorado does) to maintain consistency with the rest of the platform.

Key stakeholders: network operators, security analysts, capacity planners.

## Delivery Strategy

This change describes the target parity end-state and the decisions needed to get there. It is intentionally too large to implement as a single PR. The implementation MUST be split into smaller, independently shippable OpenSpec changes with clear acceptance criteria (route + state model first, then chart suite, then enrichment and performance).

## Goals / Non-Goals

### Goals

- Feature parity with akvorado's Visualize page (chart types, dimensions, filters, bidirectional, previous period)
- Feature parity with akvorado's dashboard homepage (top-N widgets, flow rate, exporters)
- Interface name resolution via SNMP inventory join (no new polling needed if we already have the data)
- Deep application classification (IP ranges for major services + admin rules)
- AlienVault OTX as a feed source for threat intel
- All visualizations driven by SRQL queries
- D3-based charts for consistency
- Compressed shareable URLs
- Multi-resolution continuous aggregates for performance at scale

### Non-Goals

- Kafka integration (we use NATS JetStream)
- ClickHouse migration (we stay on TimescaleDB)
- Full DPI/packet inspection (we work with flow metadata only)
- sFlow support (NetFlow v5/v9/IPFIX only for now)
- Real-time streaming visualization (we do periodic refresh)
- Replacing the `/observability` page (it remains for logs/traces/metrics/events/alerts)

## Decisions

### Decision: Dedicated `/netflow` Route Instead of Tab

Akvorado's Visualize page is a standalone page with a left options panel and right visualization panel. This layout doesn't fit inside a tab. The NetFlows tab in `/observability` will redirect to `/netflow`. Cross-links between the two pages will allow navigation.

**Alternatives considered:**
- Keep as tab with expanded UI → Too cramped, can't support left panel layout
- Modal/overlay → Too disruptive, can't bookmark

### Decision: D3 for All Charts (Not ECharts)

Akvorado uses ECharts (vue-echarts). We will implement equivalent chart types in D3 to maintain consistency with existing D3 charts in the platform. D3 gives us more control over interactivity patterns with LiveView hooks.

**Alternatives considered:**
- ECharts → Would introduce a second charting library, inconsistent with existing D3 charts
- Chart.js → Less flexible than D3 for custom chart types like Sankey

### Decision: SRQL-First Filter And Dimension Model (No Second Expression Language)

Akvorado uses a separate SQL-like filter language. ServiceRadar MUST keep a single query language for NetFlow analytics: SRQL. The Visualize UI will build SRQL queries (and optionally store a structured state model for the UI) but the underlying execution path is SRQL only.

**Alternatives considered:**
- Add an akvorado-like filter language → duplicates parsing/validation and breaks the "all SRQL" constraint

### Decision: Shareable State Uses A Versioned Compressed Payload

The Visualize page options are a structured state (time range, dimensions, units, graph type, options like bidirectional/previous period). This state will be encoded in the URL as a single parameter (example: `nf=v1-<compressed>`), with a version prefix and strict validation.

When state cannot be parsed, the UI must fall back to sane defaults and preserve the raw SRQL query string.

### Decision: Interface Resolution via Inventory Join

Akvorado gets interface names from SNMP polling embedded in its enrichment pipeline. We already collect SNMP interface data in our inventory system (Interface resource with if_index, if_name, if_description, if_speed, device_id). We can join flow `input_snmp`/`output_snmp` + `sampler_address` → device_id + if_index → interface record at either:

1. **Query time** (SRQL LEFT JOIN to interface cache view)
2. **Enrichment time** (background worker populates flow-adjacent cache table)

We choose **option 2 (enrichment-time)** with a bounded cache table (`platform.flow_interface_cache`) keyed by `(sampler_address, if_index)` that the enrichment worker populates from the interface inventory. This avoids JOIN overhead on every query and follows our existing enrichment pattern.

**Alternatives considered:**
- Query-time JOIN → Adds latency to every SRQL query, requires complex SQL generation
- Embed in flow record → Would require re-processing historical data

### Decision: Application Classification Tiers

Three tiers of application classification:

1. **Baseline port mapping** (existing) - Common services by protocol+port
2. **IP range databases** (new) - Well-known service IP ranges (Netflix, Google, Microsoft, Cloudflare, AWS, gaming services). Admin-configurable CSV/JSON import.
3. **Admin override rules** (existing) - Priority-based rules with CIDR+port matching

The IP range database is a new `platform.netflow_app_ip_ranges` table populated by configurable import sources. The SRQL app classification expression becomes: `COALESCE(admin_rule, ip_range_match, port_baseline, 'unknown')`.

### Decision: AlienVault OTX as Feed Source

AlienVault OTX provides a public API for threat intelligence indicators. We add it as a configured feed provider type alongside the existing generic CIDR feed support. The `ThreatIntelFeedRefreshWorker` gains a new parser for the OTX API response format (JSON with indicator objects).

### Decision: Multi-Resolution Continuous Aggregates

TimescaleDB continuous aggregates at 5min, 1h, and 1d resolutions. SRQL selects resolution automatically:
- Query window < 6h → raw data
- 6h-48h → 5min aggregate
- 2d-30d → 1h aggregate
- 30d+ → 1d aggregate

This mirrors akvorado's multi-resolution table approach but uses TimescaleDB's native feature.

### Decision: Network Dictionary System

A new `platform.network_dictionaries` + `platform.network_dictionary_entries` pair of tables allows admins to define arbitrary metadata for IP ranges. SRQL gains `net:<dictionary_name>:<attribute>` as a group-by dimension. This replaces akvorado's ClickHouse dictionary system with a PostgreSQL-native equivalent.

## Risks / Trade-offs

- **D3 chart complexity**: Building 5 chart types in D3 with full interactivity (brush, legend toggle, tooltips with statistics, bidirectional axes) is significant work. Each chart type needs its own LiveView hook.
  → Mitigation: Build a shared D3 utility module for axes, tooltips, legends, and responsive layout. Start with stacked area (most common) and extend.

- **Interface resolution cache freshness**: If interface inventory changes, the cache may lag.
  → Mitigation: Cache TTL of 1h with invalidation on interface inventory changes via PubSub.

- **Application IP range maintenance**: Well-known service IP ranges change frequently.
  → Mitigation: Provide configurable import sources and scheduled refresh. Ship a default dataset and let operators customize.

- **Continuous aggregate migration**: Adding CAGGs to existing hypertables requires careful migration.
  → Mitigation: Create CAGGs as new objects (no alter existing), test rollback path.

- **URL state size**: Complex queries may produce large URL state even with compression.
  → Mitigation: Use LZString compression, fall back to server-side saved views for very large states.

## Migration Plan

1. Create new route `/netflow` with basic layout and SRQL-backed query execution
2. Add redirect from `/observability` netflows tab to `/netflow` (preserve SRQL query in URL)
3. Extract/standardize D3 hooks into a shared chart toolkit, then add missing chart types
4. Add dimension selector and ranking/truncation controls (builds SRQL queries)
5. Add interface/exporter cache and derived SRQL dimensions; then add units/pct-of-capacity
6. Add CAGGs and SRQL auto-resolution for scale
7. Add deep enrichment (app IP ranges, dictionaries, OTX)
8. Build dashboard homepage widgets
9. Remove legacy netflows tab code from observability page

Rollback: Each step is independently reversible. The redirect can be removed to restore the old tab. New tables/CAGGs can be dropped without affecting raw flow data.

## Open Questions

- Should we support custom user-defined chart dashboards (drag-and-drop widget arrangement) in v1, or defer to v2?
- Do we need to collect additional NetFlow template fields (MPLS, NAT, BGP communities) at the collector level, or can we defer those?
- Should the network dictionary system support automatic import from external sources (e.g., cloud provider IP ranges from AWS/GCP/Azure published lists)?
