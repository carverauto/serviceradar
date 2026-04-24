## 1. Spec And Design
- [x] 1.1 Draft `proposal.md`/`design.md`/`tasks.md` and delta specs for `observability-netflow` and `srql`
- [x] 1.2 Validate change with `openspec validate add-netflow-advanced-visualizations --strict`

## 2. SRQL Enhancements
- [x] 2.1 Add geo-enriched flow grouping fields (src/dst country at minimum) backed by `platform.ip_geo_enrichment_cache`
- [x] 2.2 Add SRQL parsing/translation tests for geo group-by queries
- [x] 2.3 Add SRQL guardrails for Sankey query shapes (time window required, top-N caps)

## 3. Web-NG UI
- [x] 3.1 Add Sankey visualization driven by SRQL `stats` query (subnet -> service/proto -> subnet) and drill-down interactions
- [x] 3.2 Add global heatmap visualization driven by SRQL geo aggregation (country-level minimum) and drill-down interactions
- [x] 3.3 Add time-series comparison overlay (previous window / yesterday) implemented as a second SRQL query with aligned buckets
- [x] 3.4 Ensure all chart series data is SRQL-driven (no Ecto queries for chart data)

## 4. Validation
- [x] 4.1 Add/extend UI tests for visualization rendering and drill-down filter behavior
- [x] 4.2 Validate performance on large flow volumes (explain/analyze representative SRQL queries)

## 5. Demo Deployment Validation (Post-Approval)
- [x] 5.1 Fix SRQL drill-down time range encoding to use `time:"[start,end]"` (SRQL `time:` token must be scalar)
- [x] 5.2 Fix Sankey preselection filter field to use SRQL `dst_endpoint_port` (not `dst_port`)
- [x] 5.3 Add `GEOLITE_CITY_ENABLED` runtime gate and fix `runtime.exs` list concat so releases boot cleanly
- [x] 5.4 Mount shared GeoLite MMDB storage into `core` and `web-ng` so enrichment jobs can read the downloaded DBs
- [x] 5.5 Verify GeoLite downloads succeed under demo egress policy and that `ip_geo_enrichment_cache` fills `country_iso2`/`asn`
- [ ] 5.6 Verify Sankey and Geo heatmap render non-empty in `demo` for `time:last_1h` and `time:last_24h`

Notes:
- Performance validation was run against local Docker CNPG with 400k synthetic flow rows.
- Geo heatmap (24h, join to `ip_geo_enrichment_cache`): ~191 ms execution time with parallel seq scan + hash join + group aggregate.
- Timeseries downsample (24h, 5m buckets): ~147 ms execution time using the hypertable time index.
- Sankey 3-way group-by is expensive for long windows (24h): ~6.1 s execution time with external merge sort + large group aggregate. We keep the SRQL query bounded via top-N preselection and caps; the Sankey visualization renders for any selected time window and may be slower for longer windows. With `time:last_1h`, the same 3-way group-by runs in ~99 ms (bitmap scan on the hypertable time index + hash aggregate).
- Sankey filter bugfix: ensure the preselection filter uses `dst_endpoint_port` (SRQL field name) rather than `dst_port`, otherwise edges can be empty.

Recent demo blockers (as of 2026-02-08):
- SRQL `time:[start,end]` ranges were being parsed as a list by the top-level token parser, which caused errors like `expected scalar value` on bucket drill-down and could cascade into empty Sankey/heatmap widgets after interaction. Fixed by treating the raw `time:` token value as a scalar when parsing SRQL.
- The NetFlow Sankey UI is being migrated from a server-rendered SVG to a LiveView hook using `d3-sankey` so it renders reliably and looks consistent at different sizes.
