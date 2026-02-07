## 1. Spec And Design
- [x] 1.1 Confirm current NetFlow dashboard behavior in `web-ng/` (widgets, table fields, refresh model)
- [x] 1.2 Confirm current flows storage shape (OCSF network activity table(s), hypertable status, indexes)
- [x] 1.3 Confirm current SRQL `in:flows` support and identify missing tokens needed for dashboard queries

Notes (1.2):
`ocsf_network_activity` is created by `elixir/serviceradar_core/priv/repo/migrations/20260201072922_create_ocsf_network_activity.exs` in the `platform` schema with `time TIMESTAMPTZ NOT NULL` and a `maybe_create_hypertable/2` helper that converts it to a TimescaleDB hypertable when the `timescaledb` extension is present.
Indexes already exist for the primary dashboard filters and widgets: `(src_endpoint_ip, time DESC)`, `(dst_endpoint_ip, time DESC)`, `(protocol_num, time DESC)`, `(src_endpoint_port, time DESC)` (partial), `(dst_endpoint_port, time DESC)` (partial), `(sampler_address, time DESC)`, GIN on `ocsf_payload`, plus helper indexes for top talkers/ports and `(partition, time DESC)`.
Retention/TTL for raw flows is not set in this migration and remains part of the retention-policy tasks.

## 2. CNPG / Timescale Changes
- [x] 2.1 Add migrations to enforce raw NetFlow retention TTL (default 7 days, configurable)
- [x] 2.2 Add migrations for flow rollup continuous aggregates used by widgets (top talkers/ports, traffic over time)
- [ ] 2.3 Add migrations for enrichment cache tables (GeoIP/ASN, rDNS) with TTL and bounded growth controls
- [ ] 2.4 Add indexes needed for common filters (time, src_ip, dst_ip, port, protocol, asn, directionality)

Notes (2.4):
The base `ocsf_network_activity` migration already includes indexes for `src_endpoint_ip`, `dst_endpoint_ip`, `protocol_num`, `src_endpoint_port`, `dst_endpoint_port`, and `sampler_address` paired with `time DESC`. Added ASN indexes in `elixir/serviceradar_core/priv/repo/migrations/20260207094500_add_ocsf_network_activity_asn_indexes.exs`. Directionality tagging indexes will be added once directionality fields are implemented.

## 3. SRQL Enhancements
- [x] 3.1 Add flow aggregation query support (stats/group-by) for `in:flows` needed by the UI widgets
- [x] 3.2 Add time-bucketing support for flow time-series chart queries
- [x] 3.3 Add SRQL tokens for CIDR aggregation (group-by subnet) or an equivalent query shape
- [x] 3.4 Add tests for SRQL parsing/translation for the new flow aggregation patterns

## 4. Enrichment Pipeline
- [ ] 4.1 Implement GeoIP + ASN lookups using a local DB (no external API calls at query time)
- [ ] 4.2 Implement rDNS lookup with strict timeouts + caching
- [x] 4.3 Implement service tagging for common ports (static mapping + override hook)
- [ ] 4.4 Implement directionality tagging based on configured local CIDRs
- [ ] 4.5 Add a background refresh/update mechanism for enrichment data sources where applicable

## 5. Web-NG UI Enhancements
- [x] 5.1 Add/extend dashboard widgets: top talkers, top ports, protocol distribution, total bandwidth, active flows
- [x] 5.2 Add traffic time-series chart (stacked by protocol or service where feasible)
- [x] 5.3 Add drill-down interactions: clicking chart segments applies filters to the flows table
- [x] 5.4 Add compact/striped table mode toggle and consistent unit auto-scaling (bytes, bps, pps)
- [x] 5.5 Add row detail side panel with enrichment details and “related flows” pivot actions
- [x] 5.6 Ensure filters are server-side, paginated, and URL-addressable (shareable deep links)

## 6. Security Intelligence (Optional / Phased)
- [ ] 6.1 Add threat intel indicator matching and UI badges (feature-flagged)
- [ ] 6.2 Add simple anomaly flags against a baseline window (feature-flagged)
- [ ] 6.3 Add port scan detection heuristic and surfacing in UI (feature-flagged)

## 7. Validation
- [ ] 7.1 Add/update pipeline test coverage (docker compose / quick-test) to exercise new widget queries
- [ ] 7.2 Validate UI responsiveness with large flow volumes (pagination + rollups)
- [x] 7.3 Run `openspec validate add-netflow-observability-dashboard --strict`
