# Design: IP/CIDR prefix tagging with NetBox import and flow enrichment

## Context

ServiceRadar ingests NetFlow/sFlow/IPFIX via the Rust `flow-collector`, which
publishes protobuf `FlowMessage`s to JetStream subjects `flows.raw.netflow` /
`flows.raw.sflow`. The Elixir EventWriter Broadway pipeline (running as a cluster
singleton on the Postgres-advisory-lock coordinator node, key `42_600_101`) consumes
them: `Processors.Flows` calls `FlowEnrichment.enrich/1` per row and bulk-inserts
OCSF rows into the `platform.ocsf_network_activity` hypertable.

Existing longest-prefix matching happens in SQL per uncached IP
(`($1)::inet <<= c.cidr ORDER BY masklen(c.cidr) DESC LIMIT 1`) against
`platform.netflow_provider_cidrs` (~388k rows, GiST), fronted by a per-batch process
dictionary cache and the cross-batch ETS `ProviderCidrCache`. There is no in-memory
trie anywhere in the repo and no tag concept on flow rows.

The Elixir tier (core-elx, web-ng, agent-gateway) shares the `serviceradar_core`
library and one mTLS ERTS cluster (libcluster 3.5, horde 0.10). Established patterns
this design reuses: snapshot-promotion reference datasets
(`netflow_provider_dataset_snapshots`), per-node dataset loaders (GeoIP MMDB
workers), PubSub cache invalidation (`Identity.RBAC.Cache`), and `:persistent_term`
for read-hot shared data (Geolix, gateway identity config).

NetBox status: the Integrations settings UI already collects NetBox url/token/
verify_ssl credentials, `DiscoverySourceNetbox` and `IDENTITY_KIND_NETBOX_ID` exist,
and `docs/docs/netbox.md` documents a connector - but the driver itself was deleted
on 2026-01-17 (`cleanup (#2328)`); `go/pkg/agent/sync_source_drivers.go` registers
only Armis. Prior art on NetBox API pitfalls: archived change
`2026-01-02-fix-netbox-pagination` (paginated list responses silently truncating
inventory).

Prior art for the data structure: kentik/patricia, a Go patricia trie built to avoid
GC pressure from millions of pointer-linked nodes by using flat arrays and
index-based links.

## Goals / Non-Goals

- Goals:
  - Tag every ingested flow's src/dst IP with the most-specific matching prefix tags
    at sub-microsecond, zero-DB-round-trip cost on the hot path.
  - Import prefix tags from NetBox on a schedule, with manual entries supported.
  - Make tags queryable in SRQL and visible/filterable in the flow UI.
  - Keep the engine swappable (pure Elixir now, Rustler NIF if benchmarks demand).
  - (Amendment 2026-07-18) Make the engine the single LPM implementation for
    every prefix-shaped enrichment: hosting-provider CIDRs, threat-intel
    IP/CIDR indicators, RPZ hostile-IP triggers - one engine, many tag
    sources with independent cadences.
- Non-Goals:
  - Consolidating `netflow_local_cidrs` direction classification (evaluated as
    a follow-up once provider consolidation lands).
  - Importing GeoIP/ipinfo MMDB datasets into the trie (Geolix stays the geo
    engine; only derived tags are emitted).
  - Infoblox import (the snapshot/source model is built source-agnostic; the
    importer ships later).
  - Restoring NetBox device-inventory sync (shipped separately as the
    netbox-inventory wasm plugin, PR #4643).
  - Retroactive re-tagging of historical flow rows and retro-matching of new
    threat indicators against history (ingest-time tags are point-in-time
    truth; retro-matching stays with the threat-intel match table).
  - Threat-investigation UX (stays in `improve-threat-intel-investigation`).
  - Collector-side tagging or any change to the Rust flow-collector.
  - Multitenancy features (single-deployment rule).

## Decisions

- Decision: Pure Elixir trie engine behind a `ServiceRadar.PrefixTags.Engine`
  behaviour (`lookup/2` returning the most-specific-first tag chain, `build/1`,
  `stats/0`), IPv4 and IPv6 tries kept separate.
  - Alternatives considered:
    - Rustler NIF (SRQL precedent exists): only accelerates the innermost lookup,
      which is not the bottleneck at ~10k lookups/s (2 lookups/flow at ~5k flows/s;
      low-single-digit microseconds per pure-Elixir lookup is a few percent of one
      core). Adds NIF build complexity (Bazel cross-compile, crate vendoring) to
      `serviceradar_core`, which has no NIF today. Kept as the fallback: the
      behaviour boundary plus an M1 benchmark gate (<= 5% added P99 EventWriter
      flow-batch latency at a 500k-prefix trie) decides.
    - Standalone Rust consumer republishing `flows.enriched.*`: adds a deployable,
      an extra stream hop, and its own prefix-distribution channel while doing
      nothing about the actual EventWriter singleton bottleneck. Rejected for now;
      revisit only as part of a broader flow-pipeline scaling effort.
    - The `iptrie` hex package vs a small project-owned implementation: decided at
      implementation time behind the behaviour; either way wrapped by the
      project-owned module per the wrapper convention.
- Decision: `:persistent_term` snapshot storage under a versioned key, swapped
  atomically per import (build new term, flip the active-version pointer, erase the
  old term). This is the BEAM analogue of kentik/patricia's GC story: reads are
  lock-free, copy-free, and invisible to per-process GC; the global-GC cost of
  persistent_term writes is paid once per import, never per lookup.
  - Alternatives considered: ETS (read concurrency is good but terms are copied on
    read and large tries fragment across objects); process-held state (serializes
    lookups through one mailbox); DeltaCrdt replication (wrong tool - prefix data is
    reference data with DB truth, merge semantics buy nothing).
- Decision: Full per-node replication, not sharding. CNPG is the source of truth;
  a `PrefixTags.Loader` GenServer in each node's supervision tree builds the trie
  from the active snapshot on boot, subscribes to a `prefix_tags:snapshot` PubSub
  topic, and reloads on invalidation broadcast or reconnect.
  - Rationale: ingest enrichment runs on exactly one node (the coordinator
    singleton), so the hot path only needs a local trie; web-ng nodes replicate for
    interactive preview lookups. Prefix counts (10^2-10^5 from NetBox, ~388k more
    if provider CIDRs are consolidated later) are far below the scale where
    sharding pays for its network hop. Horde's role is unchanged (process
    registry); no new Horde-sharded state is introduced.
- Decision: Schema follows the reference-dataset snapshot pattern.
  `platform.prefix_tag_snapshots` (source, status, single-active partial unique
  index per source, record_count, source metadata/etag/hash) and
  `platform.prefix_tags` (snapshot_id FK ON DELETE CASCADE, prefix CIDR with GiST
  index for ad-hoc SQL, vrf, tags jsonb, normalized site/role/tenant/status
  columns). Manual entries live in a permanent `manual` source whose rows are not
  snapshot-cycled. All schema via Elixir migrations in the `platform` schema; Ash
  resources for every table; ingestion runs zero DDL.
- Decision: Flow rows gain `src_prefix_tags jsonb`, `dst_prefix_tags jsonb`,
  `src_prefix_tags_source text`, `dst_prefix_tags_source text` (matching the
  existing `*_source` provenance convention) plus a GIN index on the tag columns,
  and the same data mirrored into `ocsf_payload.enrichment`. Additive-only
  hypertable migration; old rows read as untagged.
- Decision: The enrichment hook lives beside `provider_for_ip/1` inside
  `FlowEnrichment`, called from `Processors.Flows.parse_flow`. Feature flag
  `:prefix_tag_enrichment_enabled` (default off), fail-open: any lookup error
  yields an untagged row, never a dropped flow. This keeps flow processing
  core-owned, consistent with `add-event-writer-processor-contributions` (flow
  processors stay platform primitives).
- Decision: The NetBox importer is a core-side Oban `:maintenance` worker
  (`PrefixTags.NetboxImportWorker`) mirroring
  `NetflowProviderDatasetRefreshWorker`, reading credentials from the existing
  Integrations settings source.
  - Alternatives considered: agent-embedded sync driver
    (`go/pkg/agent/syncsources/netbox`) - right seam for restoring device
    inventory sync, wrong one for a reference dataset that only core consumes;
    Wasm plugin per `add-external-inventory-wasm-plugin-contract` - that contract
    targets device inventory, and the GeoIP/provider-CIDR precedent already places
    reference-dataset importers in core. Recorded as an open question for review.
  - Import semantics: follow NetBox `next` pagination to exhaustion, validate the
    fetched row count against NetBox's `count`, fail fast on any HTTP/decode
    error, and never promote a partial snapshot (all lessons from the archived
    pagination change carried forward as acceptance criteria).
  - Tag mapping: explicit NetBox tags become `netbox:tag:<slug>`; site, role,
    tenant, status, vrf become namespaced tags (`site:<slug>`, `role:<slug>`, ...).
    The mapping (which dimensions to import, namespace allowlist, max tags per
    prefix) is configurable with sensible defaults.

- Decision (amendment 2026-07-18): Per-source trie instances, merged at lookup
  time. Each tag source (netbox, manual, provider, ti, dns-policy) compiles
  into its own versioned `:persistent_term` trie and swaps independently;
  `lookup/2` concatenates the most-specific-first chains across sources. This
  keeps a high-churn CTI refresh from paying the rebuild cost of the large,
  slow-moving provider dataset, and lets each source carry its own cadence,
  TTL, and telemetry.
  - Alternatives considered: one merged trie per import (simplest, but every
    CTI refresh rebuilds ~400k provider prefixes and the persistent_term swap
    cost scales with the union); DB-side merge views (reintroduces the SQL hot
    path this change removes).
- Decision (amendment): The hosting-provider dataset becomes a `provider:` tag
  source. The existing snapshot tables (`netflow_provider_dataset_snapshots` /
  `netflow_provider_cidrs`) remain the import pipeline; a source adapter
  compiles the active snapshot into a provider trie. `FlowEnrichment`'s
  provider lookup is served from the engine, the `ProviderCidrCache` ETS layer
  and per-IP GiST queries are retired, and the `src/dst_hosting_provider`
  columns keep their exact semantics (populated from the provider tag chain).
- Decision (amendment): Geo tags are derived, not stored. At the enrichment
  hook, the existing Geolix MMDB lookup (already per-node, in-memory LPM)
  yields `geo:country:<iso>` and `geo:asn:<asn>` tags behind a separate flag.
  Rationale: MMDB is a purpose-built prefix database with millions of rows and
  rich records; duplicating it into CNPG snapshot tables would add massive
  churn for zero lookup-latency win. This follows the wrap-don't-reimplement
  rule - the trie and Geolix are two engines behind one hook.
- Decision (amendment): Threat-intel indicators are a `ti:` tag source with
  advisory semantics. An importer materializes current IP/CIDR indicators
  (AlienVault OTX first, via the existing feed plumbing) into a high-cadence
  snapshot; expired indicators drop out on refresh. Ingest-time `ti:` tags are
  point-in-time evidence ("this IP was on a blocklist when the flow was
  observed") and are documented as such everywhere they surface. Authoritative
  threat matching - including retro-matching new indicators against historical
  flows - remains the `threat_intel_matches` path owned by
  `improve-threat-intel-investigation`; that path adopts this engine for its
  current-matching LPM instead of maintaining a second implementation.
- Decision (amendment): RPZ/PowerDNS hostile-IP triggers become a
  `dns-policy:` tag source via periodic materialization (stream-to-reference
  inversion done on a schedule, not per-event), reusing the same snapshot
  promotion and advisory semantics as `ti:`.
- Decision (amendment): PostGIS proximity on the geo cache, not the
  hypertable. Today geo reaches the UI by joining flows against
  `platform.ip_geo_enrichment_cache` (ip -> asn/country/city + plain float
  lat/lng, populated from observed IPs) at the presentation layer. PostGIS is
  already loaded and used by the FieldSurvey/WiFi-map tables
  (`geometry(Point, 4326)` + GiST). This change adds the same pattern to the
  geo cache: a geometry column derived from lat/lng plus a GiST index, so
  proximity queries (`ST_DWithin` joined to flows by IP) work server-side.
  Per-row geometry on `ocsf_network_activity` is rejected (hypertable bloat;
  the join surface is the right home). SRQL gains an in-scope proximity
  filter for flows: the translation runs `ST_DWithin` against the indexed
  cache to produce an IP set, then filters flows by src/dst IP membership -
  spatial cost scales with the cache, flow cost rides existing indexes.
  Composed with tag filters this is the CTI shape the change is for:
  `in:flows tag:ti:otx near:"<lat>,<lng>,50km"`.

## Risks / Trade-offs

- Tag cardinality bloats the hypertable -> cap tags per prefix, importer namespace
  allowlist, GIN index only on tag columns, measure compression before enabling by
  default.
- persistent_term global GC on write -> snapshot-swap only (import-frequency
  writes); measured in the benchmark harness before the flag ships on.
- Ingest-time tags go stale as IPAM changes -> by design (point-in-time truth);
  current-mapping joins against `prefix_tags` remain possible in SQL/SRQL later.
- NetBox API drift or slow instances -> fail-fast importer with recorded fixtures
  (multi-page success, mid-pagination failure); snapshot age telemetry alerts on
  staleness rather than silently serving old tags.
- Added work on the singleton EventWriter -> benchmark gate; trie lookups are
  orders faster than the SQL LPM they replace, and provider consolidation makes
  the hot path a net win.
- High-churn `ti:`/`dns-policy:` snapshots pay a persistent_term swap per
  refresh -> per-source tries keep the swap proportional to the source's own
  size; cadence floors are configurable and telemetry tracks swap duration.
- Ingest-time `ti:` tags read as detection coverage they do not provide ->
  advisory framing in UI copy, docs, and spec scenarios; authoritative matching
  stays on `threat_intel_matches`, and investigation surfaces never source from
  tag columns alone.
- Namespace growth (provider/geo/ti/dns-policy) inflates tag-column
  cardinality -> per-namespace enable flags, tags-per-prefix caps, and
  compression measurement before defaults flip on.
- Proximity queries could tempt per-flow geometry -> rejected by design; the
  spatial predicate always runs on the geo cache (GiST) and reaches flows as an
  IP-set filter, so cost scales with cache size, not flow volume.

## Migration Plan

1. Migrations land first (snapshot/tag tables, flow columns + GIN index); no
   behavior change.
2. Engine + loaders ship with the feature flag off; importer can run and promote
   snapshots without enrichment being active (validates import against production
   NetBox safely).
3. Enable `:prefix_tag_enrichment_enabled` in dev/local, verify tagged rows, SRQL
   filters, UI chips end to end against the internal NetBox instance.
4. Enable by default once the benchmark gate and dogfood exit criteria pass.
5. Rollback: disable the flag (rows revert to untagged inserts); columns are
   additive and inert; snapshots can be deactivated without schema changes.

## Open Questions

- Does the "core never gains provider modules" principle from the Wasm plugin
  contract direction apply to reference-dataset importers, or does the
  GeoIP/provider-CIDR precedent control? (This design assumes the latter.)
- Manual entries: permanent `manual` source vs. hand-authored snapshots; and
  whether prefix tags need per-partition scoping from day one
  (`netflow_local_cidrs` is partition-scoped; this design ships global tags with a
  partition column reserved but unused).
- Should the tag-preview lookup surface on agent-gateway nodes too (edge preview),
  or is core-elx + web-ng enough for v1? (v1: core-elx + web-ng only.)
