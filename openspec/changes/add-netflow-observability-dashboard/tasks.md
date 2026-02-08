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
- [x] 2.3 Add migrations for enrichment cache tables (GeoIP/ASN, rDNS) with TTL and bounded growth controls
- [x] 2.4 Add indexes needed for common filters (time, src_ip, dst_ip, port, protocol, asn, directionality)

Notes (2.4):
The base `ocsf_network_activity` migration already includes indexes for `src_endpoint_ip`, `dst_endpoint_ip`, `protocol_num`, `src_endpoint_port`, `dst_endpoint_port`, and `sampler_address` paired with `time DESC`. Added ASN indexes in `elixir/serviceradar_core/priv/repo/migrations/20260207094500_add_ocsf_network_activity_asn_indexes.exs`.
Directionality matching is driven by `platform.netflow_local_cidrs` (added in `elixir/serviceradar_core/priv/repo/migrations/20260207110000_add_netflow_local_cidrs.exs`) with:
- a GIST index on `cidr` (partial where enabled) to accelerate `inet <<= cidr` containment checks
- `partition`, `enabled`, and `(partition, cidr)` indexes for common lookups and admin workflows.

Notes (2.3):
Added `platform.ip_geo_enrichment_cache` and `platform.ip_rdns_cache` in `elixir/serviceradar_core/priv/repo/migrations/20260207100500_add_ip_enrichment_cache_tables.exs` with `expires_at` + indexes to support TTL-based pruning and to keep growth bounded to unique IPs within the TTL window.

## 3. SRQL Enhancements
- [x] 3.1 Add flow aggregation query support (stats/group-by) for `in:flows` needed by the UI widgets
- [x] 3.2 Add time-bucketing support for flow time-series chart queries
- [x] 3.3 Add SRQL tokens for CIDR aggregation (group-by subnet) or an equivalent query shape
- [x] 3.4 Add tests for SRQL parsing/translation for the new flow aggregation patterns

## 4. Enrichment Pipeline
- [x] 4.1 Implement GeoIP + ASN lookups using a local DB (no external API calls at query time)
- [x] 4.2 Implement rDNS lookup with strict timeouts + caching
- [x] 4.3 Implement service tagging for common ports (static mapping + override hook)
- [x] 4.4 Implement directionality tagging based on configured local CIDRs
- [x] 4.5 Add a background refresh/update mechanism for enrichment data sources where applicable
- [x] 4.6 (Optional) Integrate `ipinfo.io/lite` enrichment provider with per-deployment API key (AshCloak-encrypted) and admin UI (RBAC)

Notes (4.2/4.5):
Added Ash resources `ServiceRadar.Observability.IpRdnsCache` and `ServiceRadar.Observability.IpGeoEnrichmentCache` (migrate? false) and background workers:
`ServiceRadar.Observability.IpEnrichmentRefreshWorker` (SRQL-driven candidate discovery + strict rDNS timeouts + cache upsert)
and `ServiceRadar.Observability.IpEnrichmentCleanupWorker` (TTL pruning by `expires_at`).
Added `ServiceRadar.Observability.IpEnrichmentScheduler` to ensure jobs are scheduled when Oban is available.

Notes (4.1):
Added local GeoLite2 MMDB support via `Geolix` (`geolix_adapter_mmdb2`) configured in `elixir/serviceradar_core/config/runtime.exs` and implemented lookups in `ServiceRadar.Observability.GeoIP`.
`ServiceRadar.Observability.IpEnrichmentRefreshWorker` now populates `ip_geo_enrichment_cache` from the local MMDBs (no external API calls at query time). MMDB files are refreshed daily by `ServiceRadar.Observability.GeoLiteMmdbDownloadWorker`.

Notes (4.4):
Added `platform.netflow_local_cidrs` + Ash resource `ServiceRadar.Observability.NetflowLocalCidr` (RBAC permission `settings.netflow.manage`) and an admin settings UI at `/settings/netflows` for managing local CIDRs.
SRQL `in:flows` supports `direction:<value>` filtering and `stats:... by direction` grouping via a computed direction expression that consults `netflow_local_cidrs`.
The direction computation is written to avoid repeated containment checks: it computes `src_local` and `dst_local` once (via two `EXISTS` subqueries) and then derives the label, rather than re-running `EXISTS` multiple times per row.

Perf note:
Direction is currently computed at query time (no extra column in `ocsf_network_activity`). If we later need to display direction in every raw flow row at high volumes, we may want to persist direction at ingestion time or precompute in rollups; for now we rely on the GIST index on enabled CIDRs + the optimized computed expression.

Notes (4.6):
Added `platform.netflow_settings` (singleton) with AshCloak-encrypted `ipinfo_api_key` and an admin settings UI under `/settings/netflows`.
Implemented `platform.ip_ipinfo_cache` with TTL and an ipinfo.io/lite background refresh in `ServiceRadar.Observability.IpEnrichmentRefreshWorker`.
All ipinfo usage is background-only; SRQL query execution never makes external API calls.

## 5. Web-NG UI Enhancements
- [x] 5.1 Add/extend dashboard widgets: top talkers, top ports, protocol distribution, total bandwidth, active flows
- [x] 5.2 Add traffic time-series chart, plus a stacked area chart driven by SRQL (toggle: top ports vs top talkers)
- [x] 5.3 Add drill-down interactions: clicking chart segments applies filters to the flows table
- [x] 5.4 Add compact/striped table mode toggle and consistent unit auto-scaling (bytes, bps, pps)
- [x] 5.5 Add row detail side panel with enrichment details and “related flows” pivot actions
- [x] 5.6 Ensure filters are server-side, paginated, and URL-addressable (shareable deep links)

Notes (5.3):
SRQL `time:` filters accept a scalar token. Absolute time range drill-down can be encoded as `time:"[start,end]"` (quoted) or `time:[start,end]` now that SRQL treats the raw `time:` token value as a scalar during parsing.

## 6. Security Intelligence (Optional / Phased)
- [x] 6.1 Add threat intel indicator matching and UI badges (feature-flagged)
- [x] 6.2 Add simple anomaly flags against a baseline window (feature-flagged)
- [x] 6.3 Add port scan detection heuristic and surfacing in UI (feature-flagged)

Notes (6.x):
Implemented feature-flagged security intelligence via:
- `platform.threat_intel_indicators` + `ThreatIntelFeedRefreshWorker` (feed download + upsert)
- `platform.ip_threat_intel_cache` (bounded per-IP match cache)
- `platform.netflow_port_scan_flags` computed from SRQL `count_distinct(dst_endpoint_port) by src_endpoint_ip`
- `platform.netflow_port_anomaly_flags` computed from SRQL current-window vs baseline-window bytes by `dst_endpoint_port`
Added `NetflowSecurityScheduler` + `NetflowSecurityRefreshWorker` to keep caches refreshed.
Surfacing is added to the NetFlow flow details panel (badges/summary), gated by the configured settings in `platform.netflow_settings`.

## 7. Validation
- [x] 7.1 Add/update pipeline test coverage (docker compose / quick-test) to exercise new widget queries
- [x] 7.2 Validate UI responsiveness with large flow volumes (pagination + rollups)
- [x] 7.3 Run `openspec validate add-netflow-observability-dashboard --strict`

Notes (7.1):
Added web-ng LiveView coverage for:
- NetFlow settings (create CIDR, RBAC gate) in `web-ng/test/serviceradar_web_ng_web/live/settings/netflow_live_test.exs`
- Direction chips SRQL patching in `web-ng/test/serviceradar_web_ng_web/live/log_live/netflows_test.exs`
Also ran SRQL unit tests in `rust/srql` after adding direction filter/group-by support.

Notes (7.2):
Inserted 100k synthetic flow rows into `platform.ocsf_network_activity` (hypertable) and ran `EXPLAIN (ANALYZE, BUFFERS)`
for the raw flow list shape with direction computed from `platform.netflow_local_cidrs`.
Observed:
- Time-window + `ORDER BY time DESC LIMIT 50` uses the hypertable chunk time index.
- CIDR containment checks use the partial GIST index on enabled CIDRs.
- Updated the SRQL direction expression to use a simple `CASE flags.mask WHEN ...` to avoid PostgreSQL re-evaluating the correlated
  `EXISTS` checks multiple times per row (important for the raw flows list).

Perf note:
Direction is still computed at query time. If the raw flows list ever needs direction for very large page sizes or high QPS, we can
persist direction at ingestion time or precompute it in rollups, but that's not part of this request.

## 8. Demo Deployment Validation (Post-Approval)
- [x] 8.1 Enable demo egress allowlist for GeoLite MMDB refresh from `raw.githubusercontent.com` (CIDR-based allow)
- [x] 8.2 Add `GEOLITE_CITY_ENABLED` gating and bump `web-ng` resources in demo to avoid City MMDB OOM
- [x] 8.3 Fix SRQL drill-down time bucket click to generate `time:"[start,end]"` (scalar token)
- [x] 8.4 Mount shared GeoLite MMDB storage into `core` and `web-ng` so enrichment workers can load the local DBs
- [x] 8.5 Verify `platform.ip_geo_enrichment_cache` has non-zero `country_iso2` and `asn` counts in demo after refresh
- [ ] 8.6 Verify `Traffic over time` renders points and click-through opens a valid flows list SRQL query
- [ ] 8.7 Verify rDNS, GeoIP/ASN, and ipinfo.io/lite enrichment fields appear in the NetFlow details panel and table
- [x] 8.8 Allow demo egress for ipinfo MMDB refresh, including `dl.assets.ipinfo.io` redirect target (CIDR allowlist)

Notes (8.6/8.7):
As of 2026-02-07, demo verification requires redeploying updated `core-elx` and `web-ng` images that include:
- SRQL datetime parsing fixes for the timeseries response shape (so `Traffic over time` renders points).
- SRQL time range parsing fix for absolute ranges (`time:[start,end]`) so bucket drill-down doesn't error with `expected scalar value`.
- Netflow settings fixes so saving `ipinfo_api_key` works via Ash (avoid `NoSuchAttribute :ipinfo_api_key`).
- rDNS display in the NetFlow details panel and NetFlow table (table now shows hostname on the second line when present).
- GeoIP/ASN display in the NetFlow details panel (reads from `platform.ip_geo_enrichment_cache`).
- Sankey visualization reliability improvements (SRQL-driven edges + D3 Sankey rendering via LiveView hook).
- Default NetFlow view tuned to `time:last_1h` to reduce density and align with enrichment scan window.
- Stacked traffic mix chart (protocol) rendered from SRQL bucket queries.
- ipinfo.io/lite on-demand cache fill from local MMDB when opening flow details (no external calls).
- CA trust store fix for HTTPS downloads in release images (Finch configured with `castore`) so MMDB refresh workers can download over TLS.

Demo progress (2026-02-07):
- `web-ng` pushed/restarted at `sha-2ae7e87db1a2f07779be6bd00cccad885fa494b4` (includes NetFlow table rDNS rendering fix).
- `core-elx` pushed/restarted at `sha-5cacebeab086914d5e28066b17ea76ae61c08f49` (increased GeoLite MMDB download timeout to support the ~60MB City DB).
- GeoLite MMDB files now exist in demo at `/var/lib/serviceradar/geoip/` and the enrichment refresh job populated `platform.ip_geo_enrichment_cache` with non-zero `country_iso2` and `asn` counts.
- Demo egress allowlist now includes ipinfo.io (`34.117.0.0/16`) and the observed `dl.assets.ipinfo.io` redirect targets (`104.18.22.0/24`, `104.18.23.0/24`); core downloaded `ipinfo_lite.mmdb` to `/var/lib/serviceradar/geoip/ipinfo_lite.mmdb`.

After redeploy, re-run:
- open `/observability?tab=netflows` and confirm `Traffic over time` shows points for `last_1h` and clicking a point pushes a valid SRQL query.
- open a flow detail panel and confirm GeoIP/ASN and rDNS fields populate (after the enrichment job runs at least once).
