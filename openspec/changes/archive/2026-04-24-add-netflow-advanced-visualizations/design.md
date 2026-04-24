## Context
This change extends the existing NetFlow dashboard with additional visualizations that require multi-dimensional aggregation and geo-enriched grouping.

Constraints:
- Charts MUST be SRQL-driven.
- No external API calls at query time; all enrichment must be background-populated caches.

## Goals
- Provide a Sankey diagram that makes traffic paths obvious and clickable.
- Provide a global traffic heatmap (country-level minimum) with drill-down.
- Provide relative time comparisons on the main time-series chart.
- Keep queries fast and bounded at high flow volumes.

## Non-Goals
- Inferred local CIDRs.
- Persisting per-row direction at ingestion time (unless separately required for performance).

## Data Sources
- Raw flows: `platform.ocsf_network_activity` (Timescale hypertable).
- Geo cache: `platform.ip_geo_enrichment_cache` keyed by `ip`.

## SRQL Design
### Geo-Enriched Grouping
SRQL SHALL support grouping flows by geo fields derived from `ip_geo_enrichment_cache` for both source and destination, for example:
- `src_country_iso2`, `dst_country_iso2`
- optionally `src_latitude`, `src_longitude`, `dst_latitude`, `dst_longitude`

Implementation approach:
- SRQL adds `LEFT JOIN platform.ip_geo_enrichment_cache AS src_geo ON src_geo.ip = flows.src_endpoint_ip` only when the query references any `src_*geo*` field.
- SRQL adds `LEFT JOIN platform.ip_geo_enrichment_cache AS dst_geo ON dst_geo.ip = flows.dst_endpoint_ip` only when the query references any `dst_*geo*` field.
- Group-by uses the joined fields; missing cache entries group under `NULL` (UI treats as "Unknown").

### Sankey Query Shapes
The Sankey graph will be built from one or more SRQL `stats` queries returning a flat list of weighted edges (bytes/packets).

Default path:
- `src_subnet:/24 -> service (or dst_port/protocol) -> dst_subnet:/24`

SRQL should already support multi-dimension group-by; we will add guardrails:
- cap the number of returned rows/edges (top-N)
- require an explicit time window

## UI Design
### Sankey
- Default subnet size: `/24` (toggle `/16`).
- Weight metric toggle: bytes vs packets.
- Click nodes/edges to apply filters to the flows table and update URL.

### Heatmap
- Level 1: country-level choropleth or bubble map.
- Selector: source vs destination geography.
- Click a country to apply a filter (e.g. `src_country_iso2:US`) that flows table and other widgets honor.

### Time Comparison
- Toggle: `Off | Previous window | Yesterday`.
- When enabled, issue a second SRQL query with the shifted time window; align buckets client-side and overlay series.

## Performance Guardrails
- Apply time filters and partition filters before joins.
- Cap Sankey edges/nodes by default.
- Prefer rollups/continuous aggregates when available; do not block on them for first iteration.
