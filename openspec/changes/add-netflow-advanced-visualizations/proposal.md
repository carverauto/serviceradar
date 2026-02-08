# Change: Add NetFlow Advanced Visualizations (Sankey, Geo Heatmap, Time Compare)

## Why
The current NetFlow dashboard is strong for top-N widgets and drill-down, but it is still hard to see multi-hop patterns (who talks to what over which services) and geographic traffic distribution at a glance. Operators also need fast relative comparisons ("is this unusual vs yesterday/previous window?") without leaving the dashboard.

## What Changes
- Add a Sankey diagram visualization to show `Source Subnet -> Service/Protocol -> Destination Subnet` with drill-down to the flows table.
- Add a global traffic heatmap visualization (country-level at minimum) driven by cached GeoIP enrichment.
- Add relative time comparison overlays for time-series charts (e.g. compare to previous window / yesterday) with aligned time buckets.
- Extend SRQL to support geo-enriched aggregation/group-by for flows using the existing enrichment cache tables (no external API calls at query time).
- Enforce the rule: all chart/visualization series data is produced via SRQL queries (no Ecto queries for chart data).

## Non-Goals
- Automatic inference of local CIDRs.
- Real-time external enrichment lookups at query time.
- Full-blown analytics dashboards that require large multi-query orchestration.

## Impact
- Affected specs: `observability-netflow`, `srql`.
- Affected code:
  - SRQL translator/planner for flows (geo join fields, multi-dimension grouping guardrails).
  - `web-ng/` LiveView dashboard components (Sankey, heatmap, compare overlays).
- Data model: reuses `platform.ip_geo_enrichment_cache`; no new external services required.

## Risks / Considerations
- Query cost: geo heatmap requires joining flows to GeoIP cache; SRQL must only add joins when required and must apply time filters early.
- Cardinality: Sankey edges can explode; we must cap edges/nodes (top-N) and provide sane defaults.
- UX: ensure drill-down interactions remain predictable and URL-addressable.
