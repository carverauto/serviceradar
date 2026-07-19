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
- `srql`: `in:flows` gains tag filtering over the new columns.
- `build-web-ui`: flow investigation surfaces render tag chips and tag filters; the
  Integrations settings page gains an IP tag-preview lookup.

Explicitly out of scope (follow-up changes): migrating the hosting-provider CIDR
lookup and `netflow_local_cidrs` classification into the trie (consolidation),
Infoblox import, NetBox device-inventory sync restoration in the agent sync runtime,
device-level tags, and retroactive re-tagging of historical flow rows.

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
