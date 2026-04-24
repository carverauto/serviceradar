## Context
NetFlow/IPFIX flows are ingested, transformed into OCSF network activity events, and queried in the Phoenix `web-ng` UI. The NetFlow dashboard already exists, but it is primarily a table with a few summary widgets. Issue #2681 proposes adding enrichment, richer visualizations, and interactive drill-down while remaining responsive under high-cardinality datasets.

## Goals
- Make NetFlow investigations “context first”: show hostnames, geography, ASN/ISP, and service names without forcing operators to pivot to CLI tools.
- Keep the UI responsive with large datasets via server-side filtering/pagination and pre-aggregated rollups.
- Provide a cohesive workspace where charts and the flows table stay in sync through linked filters.
- Keep enrichment deterministic and low-risk: cache aggressively and avoid introducing hard dependencies on external APIs.

## Non-Goals
- Implementing a full SIEM: threat intel and anomaly detection are lightweight value-add flags, not a new alerting subsystem.
- Adding multitenancy modes or per-customer routing beyond existing deployment scoping.
- Blocking ingestion on enrichment: enrichment can be async/derived; raw events must remain queryable.

## Architecture Notes
### Enrichment Sources
- GeoIP + ASN: prefer shipping a local MaxMind GeoLite2 DB (or equivalent) rather than calling external APIs at query time.
- rDNS: do reverse lookups through the environment’s DNS resolver with strict timeouts and caching.
- Service tagging: map well-known ports to service names locally (static table + override hook).
- Directionality: compute `Inbound/Outbound/Internal` using configured “local CIDRs”.
- Optional external enrichers (background only): allow operators to configure an enrichment provider like `ipinfo.io/lite` for higher-fidelity ASN/org metadata. API keys MUST be stored encrypted at rest (AshCloak/Cloak) and MUST NOT be used at query time (background refresh only).

### Caching Strategy
- Cache enrichment per IP with TTL and bounded size.
- Store cached results in CNPG (or a dedicated cache table) so multiple UI nodes share results.
- Ensure cache misses do not cause thundering herds; use singleflight-style de-dupe where possible.

### Query Strategy
- Use SRQL for the raw table query (`in:flows ...`) with server-side pagination and filter tokens.
- Use SRQL aggregation/rollup queries for dashboard widgets:
  - Top talkers by bytes/packets
  - Top ports by bytes/flows
  - Time-series traffic volume (bytes/sec, packets/sec) bucketed by time range
- Prefer Timescale continuous aggregates for expensive rollups over large windows.

### Security Intelligence Flags
- Threat intel: represent as an optional “indicator match” field on flow rows (source/destination), derived from periodically refreshed feeds.
- Anomaly heuristics: compute simple baselines (e.g., last 7 days) and flag large deltas; keep the initial implementation read-only and non-blocking.
- Port scan detection: heuristic counts of unique dst ports per src within a window; surface as a badge/flag.

## Data Model Notes
- Treat enriched attributes as derived fields that can be added incrementally:
  - In the near-term, enrich at query-time with cached lookups.
  - In later iterations, denormalize into derived tables/materialized views if needed for speed.
- Apply retention policies:
  - Raw flows: short TTL (e.g., 7 days, configurable)
  - Aggregated rollups: longer TTL (e.g., 30 days, configurable)

## Risks / Tradeoffs
- rDNS can be slow/unreliable: must be optional, cached, and time-bounded.
- GeoIP/ASN databases require periodic updates: need an explicit update mechanism in deployment tooling.
- High-cardinality group-bys can be expensive: requires careful SRQL constraints, indexes, and/or Timescale rollups.
