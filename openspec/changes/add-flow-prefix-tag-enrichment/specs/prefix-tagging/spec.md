# prefix-tagging Specification (Delta)

## ADDED Requirements

### Requirement: Prefix tag dataset storage

The system SHALL store IP/CIDR prefix-to-tag mappings in the `platform` schema using
snapshot-versioned tables (`prefix_tag_snapshots`, `prefix_tags`) managed exclusively
by Elixir migrations and exposed as Ash resources. Each import source (for example
`netbox`, `manual`) SHALL have at most one active snapshot, enforced by a partial
unique index, and snapshot promotion SHALL be atomic. Manual entries SHALL be
supported through a permanent `manual` source that is not replaced by scheduled
imports. Ingestion services SHALL NOT run DDL.

#### Scenario: Snapshot promotion is atomic

- **WHEN** an importer finishes writing a new snapshot and promotes it
- **THEN** the previous active snapshot for that source is deactivated and the new
  snapshot activated in a single transaction, and readers observe either the old or
  the new snapshot, never a mixture

#### Scenario: Partial imports are never promoted

- **WHEN** an import fails partway through writing prefix rows
- **THEN** the incomplete snapshot remains inactive, the previously active snapshot
  continues to serve lookups, and the failure is reported

#### Scenario: Manual entries survive scheduled imports

- **WHEN** an operator creates a manual prefix tag entry and a scheduled NetBox
  import later promotes a new snapshot
- **THEN** the manual entry remains active alongside the imported snapshot

### Requirement: Longest-prefix-match tag lookup engine

The system SHALL provide an in-memory longest-prefix-match lookup engine, owned by a
project module behind a behaviour, that returns the matching tag chain for an IPv4 or
IPv6 address ordered most-specific first. The engine SHALL serve reads without
per-lookup database queries and without per-lookup copying visible to process garbage
collection (persistent-term-backed snapshot storage). Engine updates SHALL occur only
by atomic snapshot swap.

#### Scenario: Overlapping prefixes return the full chain most-specific first

- **WHEN** `10.1.0.0/16` carries tag `site:austin` and `10.1.2.0/24` carries tag
  `role:guest-wifi`, and a lookup is performed for `10.1.2.3`
- **THEN** the result lists `role:guest-wifi` before `site:austin` and includes both

#### Scenario: Lookup with no matching prefix

- **WHEN** a lookup is performed for an address covered by no stored prefix
- **THEN** the engine returns an empty result without error and without querying the
  database

#### Scenario: Snapshot swap under concurrent lookups

- **WHEN** a new snapshot is activated while lookups are in flight
- **THEN** every lookup completes against either the old or the new trie, and no
  lookup fails or blocks on the swap

### Requirement: Cluster-wide trie replication

Each participating node (core-elx and web-ng) SHALL run a loader that builds the
lookup trie from the active snapshots in CNPG at boot, subscribes to a PubSub
invalidation topic, and rebuilds when a snapshot promotion is broadcast or when the
node reconnects to the cluster. CNPG SHALL remain the sole source of truth; the trie
is a derived, rebuildable cache.

#### Scenario: Nodes reload after snapshot promotion

- **WHEN** an import promotes a new snapshot and broadcasts invalidation
- **THEN** every subscribed node rebuilds its trie from the new active snapshot

#### Scenario: Late-joining node loads current data

- **WHEN** a node boots or rejoins the cluster after a network partition
- **THEN** its loader fetches the currently active snapshots from CNPG and serves
  lookups consistent with the rest of the cluster without requiring a new broadcast

### Requirement: Flow enrichment with prefix tags

When prefix tag enrichment is enabled, the event writer's flow processor SHALL look
up prefix tags for each flow's source and destination IP and persist the results to
`src_prefix_tags` and `dst_prefix_tags` columns with `*_source` provenance columns on
`platform.ocsf_network_activity`, mirrored into the `ocsf_payload` enrichment map.
Enrichment SHALL be fail-open: a lookup error yields an untagged row and never drops
or delays the flow beyond the enrichment call itself. Enrichment SHALL be gated by a
feature flag defaulting to off, SHALL execute only in the consumer path (the
JetStream-first ingestion architecture is unchanged), and SHALL NOT modify the flow
collector.

#### Scenario: Flow persisted with tags and provenance

- **WHEN** enrichment is enabled and a flow's destination IP falls inside a prefix
  tagged `site:austin` from the NetBox snapshot
- **THEN** the persisted row carries `site:austin` in `dst_prefix_tags`, records the
  source as `netbox` in `dst_prefix_tags_source`, and mirrors the tags in
  `ocsf_payload` enrichment

#### Scenario: Lookup failure does not drop flows

- **WHEN** the lookup engine raises an error during flow processing
- **THEN** the flow row is persisted without prefix tags and the batch completes
  normally

#### Scenario: Flag disabled means zero behavior change

- **WHEN** the feature flag is off
- **THEN** no prefix tag lookup is performed and persisted rows are identical to
  pre-change behavior

### Requirement: NetBox prefix and tag import

The system SHALL provide a scheduled importer (Oban maintenance worker) that pulls
prefixes from the NetBox IPAM API using credentials configured through the existing
Integrations settings, writes them as a new snapshot, and promotes the snapshot only
on complete success. The importer SHALL follow NetBox pagination to exhaustion,
SHALL validate the fetched row count against the API-reported total, and SHALL abort
without promotion on any HTTP, decode, or count-mismatch error. NetBox tags SHALL be
imported as `netbox:tag:<slug>`; site, role, tenant, and status SHALL map to
namespaced tags with a configurable mapping and a configurable cap on tags per
prefix.

#### Scenario: Multi-page import is complete

- **WHEN** NetBox returns prefixes across multiple paginated responses
- **THEN** the importer follows every `next` link, the promoted snapshot's record
  count matches NetBox's reported `count`, and prefixes from later pages are present

#### Scenario: Mid-pagination failure aborts cleanly

- **WHEN** a page request fails or a count mismatch is detected during import
- **THEN** the run aborts, no snapshot is promoted, the previous snapshot keeps
  serving, and the failure is surfaced in import telemetry

#### Scenario: NetBox dimensions map to namespaced tags

- **WHEN** a NetBox prefix has site `austin-dc`, role `guest-wifi`, and tag `iot`
- **THEN** the imported entry carries `site:austin-dc`, `role:guest-wifi`, and
  `netbox:tag:iot`

### Requirement: Prefix tag administration and authorization

The system SHALL require a dedicated permission, registered in the RBAC catalog,
for managing prefix tags (manual entries, import configuration, snapshot
operations). The settings UI
SHALL offer an IP tag-preview lookup that returns the tag chain an address would
receive, available to users authorized to view integrations settings.

#### Scenario: Unauthorized management is denied

- **WHEN** a user without the manage-prefix-tags permission attempts to create a
  manual prefix tag entry
- **THEN** the action is rejected by policy

#### Scenario: Tag preview returns the effective chain

- **WHEN** an authorized user previews `10.1.2.3` in the settings UI
- **THEN** the UI shows the most-specific-first tag chain the enrichment path would
  apply, served from the local node's trie without a database lookup

### Requirement: Per-source trie instances with independent cadence

The system SHALL compile each tag source (netbox, manual, provider, ti,
dns-policy) into its own versioned trie instance that swaps atomically and
independently of every other source, and lookups SHALL merge the
most-specific-first chains across all active sources with per-tag source
provenance. Refreshing a high-churn source SHALL NOT rebuild or block any
other source's trie.

#### Scenario: One source refreshes without rebuilding others

- **WHEN** the threat-intel source promotes a new snapshot while the provider
  source's trie holds hundreds of thousands of prefixes
- **THEN** only the threat-intel trie is rebuilt and swapped, and provider
  lookups proceed uninterrupted against the untouched provider trie

#### Scenario: Lookup merges chains across sources

- **WHEN** an address matches a NetBox prefix tagged `site:austin` and a
  provider prefix tagged `provider:aws`
- **THEN** the lookup result contains both tags, each attributed to its
  source, ordered most-specific first

### Requirement: Hosting-provider dataset consolidation

The system SHALL serve the hosting-provider CIDR lookup from the prefix-tag
engine as a `provider:` tag namespace compiled from the active
`netflow_provider_cidrs` snapshot. Once enabled, the per-IP SQL
longest-prefix-match queries and the cross-batch provider cache layer SHALL be
retired from the flow hot path, and the existing `src_hosting_provider` /
`dst_hosting_provider` column semantics SHALL be preserved.

#### Scenario: Provider lookup without database round trips

- **WHEN** flow enrichment resolves the hosting provider for an uncached IP
  with provider consolidation enabled
- **THEN** the result comes from the in-memory provider trie with no per-IP
  SQL query, and the persisted provider columns match what the SQL path would
  have produced

#### Scenario: Provider snapshot promotion flows through the engine

- **WHEN** the provider dataset refresh promotes a new snapshot
- **THEN** the provider trie rebuilds from it via the standard invalidation
  broadcast and subsequent lookups reflect the new dataset

### Requirement: Geo-derived tags at enrichment

When geo tag derivation is enabled, the flow enrichment hook SHALL derive
`geo:country:<iso2>` and `geo:asn:<asn>` tags from the node-resident Geolix
MMDB lookup and persist them through the same tag columns as prefix tags. The
system SHALL NOT import MMDB datasets into the prefix-tag tables or tries;
Geolix remains the geo lookup engine.

#### Scenario: Geo tags persisted alongside prefix tags

- **WHEN** geo derivation is enabled and a flow's destination IP resolves to
  country US and ASN 15169
- **THEN** the persisted destination tags include `geo:country:us` and
  `geo:asn:15169` with geo provenance, alongside any prefix-derived tags

#### Scenario: Missing geo data is not an error

- **WHEN** the MMDB has no record for an address or the MMDB is not yet
  downloaded on the node
- **THEN** the flow persists without geo tags and enrichment continues

### Requirement: Threat-intelligence tag source

The system SHALL support a threat-intelligence tag source that materializes
current IP/CIDR indicators (AlienVault OTX first) into a `ti:` tag namespace
on a configurable high-frequency cadence, honoring indicator expiry on each
refresh. Ingest-time `ti:` tags SHALL be presented as point-in-time advisory
evidence wherever they surface; authoritative threat matching, including
retro-matching new indicators against historical flows, SHALL remain with the
threat-intel match pipeline, which SHALL use this engine for its IP/CIDR
current-matching rather than a second LPM implementation.

#### Scenario: Flow observed while indicator is active

- **WHEN** an IP is covered by an active OTX indicator and a flow to it is
  ingested
- **THEN** the flow persists with the corresponding `ti:` tag and provenance
  recording the indicator source

#### Scenario: Flow observed before the indicator existed

- **WHEN** an indicator is imported after a flow to its IP was already
  persisted
- **THEN** the historical flow row is not re-tagged, and the flow remains
  discoverable through the threat-intel match pipeline rather than the tag
  columns

#### Scenario: Expired indicators stop tagging

- **WHEN** an indicator expires and the next threat-intel snapshot is promoted
- **THEN** subsequently ingested flows to that IP carry no `ti:` tag from the
  expired indicator

### Requirement: DNS-policy tag source

The system SHALL support a `dns-policy:` tag source materialized periodically
from the hostile-IP triggers of ingested PowerDNS/RPZ policy feeds, using the
same snapshot promotion, advisory semantics, and expiry handling as the
threat-intelligence source.

#### Scenario: RPZ hostile IP tags subsequent flows

- **WHEN** an RPZ feed lists an IP trigger and the dns-policy source has been
  materialized
- **THEN** subsequently ingested flows to that IP carry the corresponding
  `dns-policy:` tag with provenance

### Requirement: Prefix tagging operational telemetry

The system SHALL emit telemetry for lookup volume, trie size per address family,
active snapshot age per source, and import outcomes (duration, record count,
success/failure), sufficient to alert on stale snapshots and failing imports.

#### Scenario: Import outcome is observable

- **WHEN** a scheduled NetBox import completes or fails
- **THEN** telemetry records the outcome, duration, and record count, and the active
  snapshot age gauge resets on success

#### Scenario: Stale snapshot is alertable

- **WHEN** no successful import has promoted a snapshot within twice the configured
  poll interval
- **THEN** the snapshot age gauge exceeds its threshold so operators can alert on it
