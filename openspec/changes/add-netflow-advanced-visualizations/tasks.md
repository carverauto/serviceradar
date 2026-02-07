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
- [ ] 4.2 Validate performance on large flow volumes (explain/analyze representative SRQL queries)

Notes:
- 4.2 is still pending: we validated the SRQL-generated SQL shape (time filter applied before aggregation; geo joins only added when geo fields are referenced; multi-group-by requires explicit time + limit cap), but did not run `EXPLAIN (ANALYZE, BUFFERS)` against a live CNPG instance in this session.
