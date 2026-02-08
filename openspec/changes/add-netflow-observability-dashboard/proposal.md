# Change: NetFlow Observability Dashboard Enhancements

## Why
The current NetFlow UI provides basic “top talkers / top ports / recent flows”, but operators still have to translate raw IPs and ports into meaningful context and manually pivot between views when troubleshooting congestion or investigating suspicious traffic. Issue #2681 proposes a richer, high-context workflow that reduces MTTR by adding enrichment, interactive visualizations, and lightweight security intelligence.

## What Changes
- Introduce a dedicated NetFlow observability capability (`observability-netflow`) with requirements for:
  - Data enrichment (GeoIP, rDNS, ASN/ISP, service tagging, directionality)
  - Advanced visualizations (top talkers widgets, time-series traffic charts, optional Sankey)
  - Linked interactions (click-to-filter / drill-down between charts and the flow table)
  - High-cardinality performance guardrails (server-side filtering + pagination; cached enrichment)
  - Optional security intelligence (threat intel flags, anomaly heuristics, port scan indicators)
- Extend SRQL to support flow-specific aggregation queries needed for dashboard widgets (group-by / rollups) without scanning raw hypertables for every UI interaction.
- Extend CNPG/Timescale schema expectations to support:
  - NetFlow data retention policies (raw vs aggregated)
  - Continuous aggregates for commonly used widgets
  - Cached enrichment lookups to avoid repeated external/DNS calls.

## Impact
- Affected specs: `observability-netflow` (new), `srql`, `cnpg`
- Affected code (expected):
  - `web-ng/` NetFlow UI (dashboard layout, charts, table, detail side panel, filtering UX)
  - SRQL query translation for `in:flows` aggregations / rollups
  - CNPG migrations (Timescale retention policies, continuous aggregates, enrichment cache tables)
- Breaking changes: None intended (additive, gated to the NetFlow dashboard)
