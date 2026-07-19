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
