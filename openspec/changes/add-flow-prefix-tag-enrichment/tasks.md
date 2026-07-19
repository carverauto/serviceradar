# Tasks: add-flow-prefix-tag-enrichment

## 1. Schema and resources

- [x] 1.1 Migration: `platform.prefix_tag_snapshots` (source, status, single-active
      partial unique index per source, record_count, source_url/etag/content hash,
      timestamps) following the `netflow_provider_dataset_snapshots` pattern
- [x] 1.2 Migration: `platform.prefix_tags` (snapshot_id FK ON DELETE CASCADE,
      prefix CIDR with GiST index, vrf, tags jsonb, normalized site/role/tenant/
      status columns, reserved partition column)
- [x] 1.3 Migration: additive `ocsf_network_activity` columns `src_prefix_tags`,
      `dst_prefix_tags` (jsonb), `src_prefix_tags_source`, `dst_prefix_tags_source`
      (text), plus GIN index on the tag columns
- [x] 1.4 Ash resources for snapshots and prefix tags (manual CRUD actions on the
      `manual` source; read-only for imported snapshots) with policies
- [x] 1.5 RBAC catalog entry for manage-prefix-tags; wire policies to it

## 2. Lookup engine

- [x] 2.1 `ServiceRadar.PrefixTags.Engine` behaviour (lookup/2 most-specific-first
      chain, build/1, stats/0) and pure-Elixir implementation (IPv4 + IPv6 tries;
      decide `iptrie` hex dep vs project-owned implementation at review)
- [x] 2.2 `:persistent_term` snapshot storage with versioned keys and atomic swap
      (build new, flip pointer, erase old)
- [x] 2.3 Property tests: LPM equivalence against a SQL
      `inet <<= cidr ORDER BY masklen DESC` oracle on randomized prefix sets;
      overlapping-prefix chain ordering; IPv6; empty-result behavior
- [x] 2.4 Concurrency test: snapshot swap under concurrent lookups (no failures, no
      blocking)
- [x] 2.5 Benchmark harness: 500k-prefix trie, 50k lookups/s synthetic; record the
      persistent_term swap cost; document the <=5% P99 EventWriter flow-batch
      latency gate result (gate failure triggers the Rustler NIF decision per
      design.md)

## 3. Replication and loaders

- [x] 3.1 `PrefixTags.Loader` GenServer: build trie from active snapshots at boot,
      subscribe to `prefix_tags:snapshot` PubSub topic, rebuild on broadcast and on
      cluster reconnect
- [x] 3.2 Supervision wiring in serviceradar_core (core-elx) and web-ng trees;
      agent-gateway excluded in v1
- [x] 3.3 Telemetry: lookup counters, trie size per address family, active snapshot
      age gauge per source, rebuild duration

## 4. Flow enrichment

- [x] 4.1 Feature flag `:prefix_tag_enrichment_enabled` (default **off**; enable
      only after migrations are applied on every EventWriter node)
- [x] 4.2 Hook in `FlowEnrichment` beside `provider_for_ip/1`: src/dst lookups per
      row, results into the row map (columns + provenance) and
      `ocsf_payload.enrichment`; fail-open on any engine error
- [x] 4.3 Processor tests: tagged row persisted with provenance; engine error yields
      untagged row and completed batch; flag off yields byte-identical rows
- [x] 4.4 Verify insert path handles the new columns within the bind-parameter
      budget chunking in `BulkInsert`

## 5. NetBox importer

- [x] 5.1 `PrefixTags.NetboxImportWorker` (Oban `:maintenance`): read credentials
      from the Integrations settings source; pull `/api/ipam/prefixes/` and
      `/api/ipam/aggregates/`; follow `next` pagination to exhaustion
- [x] 5.2 Snapshot write + count validation against NetBox `count`; fail-fast on
      HTTP/decode/count-mismatch; promote + broadcast only on complete success
- [x] 5.3 Tag mapping: `netbox:tag:<slug>` plus configurable site/role/tenant/
      status/vrf namespacing and tags-per-prefix cap, with defaults
- [x] 5.4 Scheduling: configurable poll interval registered in the cron/Oban config
      of the deployed release (core-elx runtime.exs), honoring the coordinator
      singleton pattern
- [x] 5.5 Importer tests against recorded fixtures: multi-page success,
      mid-pagination failure (no promotion), count mismatch, credential absence
- [x] 5.6 Import outcome telemetry (duration, record count, success/failure) and
      snapshot-age alerting threshold documentation

## 6. SRQL

- [x] 6.1 Diesel schema for the new `ocsf_network_activity` tag columns
- [x] 6.2 `tag`, `src_tag`, `dst_tag` filters in `rust/srql/src/query/flows.rs`
      translating to indexed jsonb predicates; composition with existing filters
- [x] 6.3 Parser/translation tests including combined tag + CIDR + time-range
      queries; `cargo fmt` + `cargo clippy` on touched crates; `bazel build
      //rust/...` verification

## 7. Web UI

- [x] 7.1 Tag chips on flow listing and detail views (src/dst), untagged rows
      unchanged; daisyUI styling consistent with existing enrichment display
- [x] 7.2 Tag filter control on the flow listing wired to the SRQL tag filter
- [x] 7.3 IP tag-preview input in Integrations settings served from the local
      node's trie; authorized per integrations-settings visibility
- [x] 7.4 LiveView tests for chips, filter, preview, and RBAC denial

## 8. Verification and docs

- [x] 8.1 `openspec validate add-flow-prefix-tag-enrichment --strict` passes
- [x] 8.2 Integration run on the srql-fixtures scratch DB: migrations, Ash actions,
      importer fixtures
      (`test/serviceradar/prefix_tags/integration_test.exs` — fixture HTTP, no live NetBox)
- [ ] 8.3 E2E dogfood: importer pointed at the internal NetBox instance in the
      local/dev stack; verify tagged rows in `ocsf_network_activity`, SRQL
      `in:flows tag:...` results, and UI chips end to end
- [x] 8.4 Ops runbook under `docs/docs/` (enabling the flag, import monitoring,
      staleness alerting, rollback via flag)
- [x] 8.5 Update `docs/docs/netbox.md` to reflect what the integration actually
      does after this change (prefix/tag import; device sync status called out
      honestly)

## 9. Per-source trie namespaces (amendment 2026-07-18)

- [x] 9.1 Split the engine store into per-source versioned tries
      (netbox/manual/provider/ti/dns-policy) with independent atomic swap;
      lookup merges most-specific-first chains across sources with per-tag
      source provenance
- [x] 9.2 Loader + PubSub invalidation carry the source identifier so one
      source's promotion rebuilds only its own trie
- [x] 9.3 Telemetry: per-source trie size, swap duration, snapshot age; tests
      covering concurrent per-source swaps

## 10. Hosting-provider consolidation (amendment)

- [x] 10.1 Provider source adapter: compile the active
      `netflow_provider_cidrs` snapshot into a `provider:` trie namespace
- [x] 10.2 Serve `FlowEnrichment` provider lookups from the engine behind a
      flag; preserve `src/dst_hosting_provider` column semantics (parity test
      against the SQL oracle on the live dataset shape)
- [x] 10.3 Retire `ProviderCidrCache` and the per-IP GiST query path once the
      flag defaults on; remove dead cache config
- [x] 10.4 Re-run the benchmark gate with the provider trie loaded (~400k
      prefixes) alongside NetBox tags

## 11. Geo-derived tags + PostGIS proximity (amendment)

- [x] 11.1 Enrichment hook derives `geo:country:`/`geo:asn:` tags from the
      resident Geolix lookup behind `:geo_tag_derivation_enabled`; fail-open
      when MMDB absent
- [x] 11.2 Migration: `geometry(Point, 4326)` column on
      `platform.ip_geo_enrichment_cache` derived from latitude/longitude
      (FieldSurvey/WiFi-map pattern) + GiST index; backfill + refresh-worker
      population
- [x] 11.3 SRQL proximity filter for `in:flows`: parse coordinate+radius term,
      translate to `ST_DWithin` IP-set subquery against the geo cache,
      compose with tag/CIDR/time filters; translation + integration tests
- [x] 11.4 Docs: SRQL cookbook entries for proximity + tag compositions

## 12. Threat-intel tag source (amendment)

- [x] 12.1 `ti:` source importer materializing current OTX IP/CIDR indicators
      into high-cadence snapshots with expiry handling
- [x] 12.2 Advisory semantics enforced in UI copy and docs (point-in-time
      evidence; authority stays with threat_intel_matches)
- [x] 12.3 Engine adoption by the CTI current-matching path (coordinate with
      improve-threat-intel-investigation; no second LPM implementation)
- [x] 12.4 Tests: active-indicator tagging, no retro-tagging, expiry stops
      tagging

## 13. DNS-policy (RPZ) tag source (amendment)

- [x] 13.1 Periodic materializer from ingested PowerDNS/RPZ hostile-IP
      triggers into a `dns-policy:` snapshot source
- [x] 13.2 Tests: trigger tagging, expiry/removal on feed update, advisory
      provenance
