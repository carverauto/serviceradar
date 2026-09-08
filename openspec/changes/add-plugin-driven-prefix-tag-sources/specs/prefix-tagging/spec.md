# prefix-tagging Specification (Delta)

## ADDED Requirements

### Requirement: Plugin-declared prefix-tag sources

The system SHALL accept prefix-tag dataset sources declared by approved signed
plugin packages via a bounded `integrations.prefix_tag_sources` descriptor.
Each declared source SHALL have a stable string `source` identifier. Core SHALL
NOT require a product-specific Elixir module named after that product in order
to register the source.

#### Scenario: Approved package claims a prefix-tag source

- **WHEN** an approved plugin package declares
  `integrations.prefix_tag_sources` with `source: "netbox"`
- **THEN** the runtime integration catalog includes that claim with the
  package's plugin id and label
- **AND** no `ServiceRadar.PrefixTags.Netbox*` module is required for the claim
  to appear

#### Scenario: Duplicate prefix-tag source claims are rejected

- **WHEN** two approved packages both claim the same `source` id under
  `prefix_tag_sources`
- **THEN** catalog load fails with a duplicate-claim error identifying both
  plugin ids

### Requirement: Generic prefix-tag snapshot ingest

The system SHALL provide a product-agnostic ingest path that accepts a versioned
complete prefix-row snapshot payload (`serviceradar.prefix_tag_snapshot.v1` or
successor), validates it, writes a building snapshot, promotes it atomically for
the payload's `source`, and broadcasts trie invalidation. Importers SHALL NOT
write CNPG schema or bypass this promote path.

#### Scenario: Valid complete snapshot is promoted

- **WHEN** ingest receives a valid payload for a catalog-claimed or
  platform-owned source with row count matching declared `record_count`
- **THEN** a new active snapshot for that source is promoted
- **AND** subscribed loaders rebuild that source's trie

#### Scenario: Partial or mismatched payloads are not promoted

- **WHEN** ingest receives a payload whose rows cannot be fully written or
  whose count does not match the declared record count
- **THEN** the incomplete snapshot is not activated
- **AND** the previously active snapshot for that source continues to serve
  lookups

#### Scenario: Unclaimed product source is rejected

- **WHEN** ingest receives a payload whose `source` is neither a platform-owned
  source nor claimed by an approved package
- **THEN** ingest rejects the payload without promoting a snapshot

### Requirement: Product-agnostic enrichment scheduling

Scheduled refresh of plugin-supplied prefix-tag sources SHALL be driven by
package-declared producer schedules and assignments (or equivalent generic
job registration), not by hard-coded aliases to product-named Oban workers in
the NetFlow enrichment dataset scheduler.

#### Scenario: Scheduler has no NetBox-specific worker alias

- **WHEN** the enrichment dataset scheduler ensures jobs
- **THEN** it does not reference a NetBox-named import worker module
- **AND** plugin-claimed prefix-tag sources are scheduled only through the
  generic descriptor/assignment path

### Requirement: Platform-owned materializers remain core

The system SHALL allow platform-owned prefix-tag sources that are not
third-party products (`manual`, `provider`, `ti`, `dns-policy`, and similar) to
be materialized by core modules. Those materializers SHALL use the same
promote/invalidate semantics as plugin ingest and MUST NOT introduce
product-specific HTTP clients for external IPAM APIs.

#### Scenario: Manual source is not replaced by plugin import

- **WHEN** a plugin promotes a snapshot for source `netbox`
- **THEN** the active `manual` snapshot and its rows remain unchanged

## REMOVED Requirements

### Requirement: Core-hosted NetBox IPAM HTTP import worker

**Reason**: NetBox is a product integration; fetch/map/schedule belong in a
signed plugin that publishes capabilities, not in `serviceradar_core`.

**Migration**: Ship a NetBox Wasm (or equivalent) plugin that emits
`serviceradar.prefix_tag_snapshot.v1` and declares `prefix_tag_sources`.
Operators assign and approve the package before the core worker is deleted.
Active `netbox` snapshots in CNPG remain valid across the cutover.
