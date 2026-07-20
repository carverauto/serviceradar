# Change: Add IP/CIDR prefix tagging with NetBox IPAM import and flow enrichment

## Why

Flow rows in `platform.ocsf_network_activity` carry technical enrichment (hosting
provider, MAC vendor, direction, ASN, geo) but no business context - nothing answers
"flows from guest-wifi to the PCI zone" or "top talkers by site/tenant". At the same
time the event writer already performs longest-prefix matching on the ingest hot path
as per-IP SQL (`inet <<= cidr ORDER BY masklen DESC`) against ~388k provider CIDRs,
mitigated by a two-level cache built after ~186k GiST round-trips in 18h. A
kentik/patricia-style in-memory LPM trie that maps prefixes to tags fixes both:
business-context tagging on every flow, and a single sub-microsecond lookup engine
that later consolidates the existing SQL matchers. NetBox is the first tag source;
its integration scaffolding (docs, Integrations UI credentials, `DiscoverySourceNetbox`,
`IDENTITY_KIND_NETBOX_ID`) survives in the repo, but the actual driver was deleted in
the 2026-01-17 sync rearchitecture (`cleanup (#2328)`), so prefix/tag import is also
the highest-leverage way to make the NetBox integration real again.

PRD with full background and build-approach analysis: forgejo issue #4641.

## What Changes

- New `prefix-tagging` capability in `elixir/serviceradar_core`:
  - Snapshot-versioned prefix-tag dataset storage in the `platform` schema
    (`prefix_tag_snapshots`, `prefix_tags`), managed by Elixir migrations and Ash
    resources, following the proven `netflow_provider_dataset_snapshots` pattern.
  - A project-owned LPM trie engine (`ServiceRadar.PrefixTags`) behind a behaviour:
    most-specific-first tag chains, IPv4 + IPv6, `:persistent_term` snapshot storage
    for GC-free reads, atomic snapshot swap on import. Pure Elixir first; the
    behaviour boundary allows a Rustler NIF swap if the benchmark gate fails
    (see design.md).
  - Per-node replication: loaders on core-elx and web-ng nodes build the trie from
    CNPG (source of truth) and reload on a Phoenix.PubSub invalidation broadcast.
  - Flow enrichment: the event writer's flow processor looks up src/dst IP tags per
    row and persists them to new `src_prefix_tags`/`dst_prefix_tags` columns (with
    `*_source` provenance) and `ocsf_payload.enrichment`. Feature-flagged, fail-open,
    consumer-side only (JetStream-first architecture unchanged; no collector changes).
  - NetBox importer: an Oban `:maintenance` worker pulls `/api/ipam/prefixes/` (and
    aggregates) using credentials already collected by the Integrations settings UI,
    with mandatory pagination handling, count validation, and fail-fast semantics
    (no partial snapshot is ever promoted). NetBox tags plus site/role/tenant/status
    map to namespaced tags.
  - RBAC entry for managing prefix tags; operational telemetry (lookup counters,
    trie size, snapshot age, import outcomes).
- `srql`: `in:flows` gains tag filtering over the new columns, and (by
  amendment) a PostGIS-backed proximity filter: `ip_geo_enrichment_cache` gains
  a `geometry(Point, 4326)` column + GiST index (the FieldSurvey/WiFi-map
  pattern), and the translator resolves proximity terms via `ST_DWithin` on the
  cache into an IP-set filter on flows - giving CTI workflows queries like
  `in:flows tag:ti:otx near:"<lat>,<lng>,50km"`.
- `build-web-ui`: flow investigation surfaces render tag chips and tag filters; the
  Integrations settings page gains an IP tag-preview lookup.
- Enrichment consolidation (added by amendment, 2026-07-18):
  - Per-source trie instances with independent snapshot cadences, merged at
    lookup time - swapping one source's snapshot never rebuilds the others.
  - Hosting-provider CIDR consolidation: the `netflow_provider_cidrs` dataset
    becomes a `provider:` tag source served by the engine; the per-IP SQL LPM
    and the `ProviderCidrCache` ETS layer are retired, and the existing
    `src/dst_hosting_provider` column behavior is preserved.
  - Geo-derived tags: the enrichment hook derives `geo:country:` and
    `geo:asn:` tags from the already-resident Geolix MMDB lookup (flagged).
    The MMDB itself is NOT imported into the trie - Geolix remains the geo
    engine; only the derived tags land in the tag columns for SRQL parity.
  - Threat-intelligence tag source: IP/CIDR indicators (AlienVault OTX first)
    become a `ti:` tag namespace with a high-churn snapshot cadence, and the
    CTI current-matching path adopts the shared engine. This absorbs the
    IP/CIDR-matching portion of `improve-threat-intel-investigation`; the
    investigation UX and the `threat_intel_matches` surface stay in that
    change. Ingest-time `ti:` tags are advisory point-in-time evidence -
    retro-matching of new indicators against historical flows remains the
    match table's job, never the tag columns'.
  - DNS-policy tag source: hostile-IP triggers from the PowerDNS/RPZ feeds we
    already ingest are periodically materialized into a `dns-policy:` tag
    namespace with the same advisory semantics.

Explicitly out of scope (follow-up changes): `netflow_local_cidrs`
direction-classification consolidation (evaluated after provider consolidation
lands), Infoblox import, importing GeoIP/ipinfo MMDB datasets into the trie,
retro-matching or re-tagging of historical flow rows (stays with
`improve-threat-intel-investigation` / the match table), threat-investigation
UX, and device-level tags. NetBox device-inventory sync restoration shipped
separately as the `netbox-inventory` wasm plugin (PR #4643).

## Impact

- Affected specs: `prefix-tagging` (new), `srql`, `build-web-ui`
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/event_writer/processors/flows.ex`,
    `flow_enrichment.ex` (enrichment hook)
  - `elixir/serviceradar_core/lib/serviceradar/prefix_tags/` (new: engine, loader,
    importer, Ash resources)
  - `elixir/serviceradar_core/priv/repo/migrations/` (snapshot + tag tables; additive
    `ocsf_network_activity` columns + GIN index)
  - `rust/srql/src/query/flows.rs` and Diesel schema (tag filter)
  - `elixir/web-ng` flow LiveViews + Integrations settings (chips, filters, preview)
  - RBAC catalog (`identity/rbac/catalog.ex`)
- Compatibility: additive columns on a hypertable; existing rows read as untagged.
  Enrichment ships behind `:prefix_tag_enrichment_enabled` (default off) and is
  fail-open, so flow ingestion behavior is unchanged until enabled.
- Coordination: no conflict with `add-event-writer-processor-contributions` (flow
  processors remain core-owned platform primitives per that proposal); UI work lands
  on the same surfaces as `improve-attributed-flow-investigation` (additive columns);
  attribution semantics remain owned by `add-netprobe-fleet-attribution`.
  `improve-threat-intel-investigation` keeps the investigation UX and the
  `threat_intel_matches` authority surface but SHALL adopt this change's engine
  for IP/CIDR current-matching instead of a second LPM implementation; its
  planned threat filters on `in:flows` can ride the `ti:` tag columns for the
  ingest-time-evidence view while authoritative matching stays on the match
  table.
