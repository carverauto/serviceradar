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

Notes:
- Performance validation was run against local Docker CNPG with 400k synthetic flow rows.
- Geo heatmap (24h, join to `ip_geo_enrichment_cache`): ~191 ms execution time with parallel seq scan + hash join + group aggregate.
- Timeseries downsample (24h, 5m buckets): ~147 ms execution time using the hypertable time index.
- Sankey 3-way group-by is expensive for long windows (24h): ~6.1 s execution time with external merge sort + large group aggregate; to keep the dashboard responsive we added a UI guardrail that disables Sankey when the selected time window is greater than 6 hours. With `time:last_1h`, the same 3-way group-by runs in ~99 ms (bitmap scan on the hypertable time index + hash aggregate).
