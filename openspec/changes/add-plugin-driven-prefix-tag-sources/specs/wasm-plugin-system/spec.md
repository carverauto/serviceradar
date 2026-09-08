# wasm-plugin-system Specification (Delta)

## ADDED Requirements

### Requirement: Prefix-tag source integration descriptors

The system SHALL accept signed plugin packages that declare zero or more
`integrations.prefix_tag_sources` entries. Each entry SHALL include a stable
`source` id and a human-readable label, and MAY bind a producer schedule already
declared on the package. Manifest validation SHALL reject unknown keys under
the entry and SHALL enforce the same id uniqueness rules used for inventory
source claims within a package.

#### Scenario: Valid prefix-tag source descriptor is accepted

- **GIVEN** a package manifest with `integrations.prefix_tag_sources` containing
  `source: "netbox"`, `label: "NetBox IPAM"`, and a valid producer schedule
  binding
- **WHEN** the package is validated
- **THEN** validation succeeds and the descriptor is stored with the package
  metadata

#### Scenario: Invalid prefix-tag source descriptor is rejected

- **GIVEN** a package manifest with a `prefix_tag_sources` entry missing
  `source` or using a disallowed id shape
- **WHEN** the package is validated
- **THEN** validation fails with a field-path error
- **AND** the package is not approved for catalog use

### Requirement: Plugins do not write prefix-tag tables directly

Plugins that supply prefix tags SHALL emit complete snapshot payloads through
the platform ingest path and SHALL NOT open database connections or issue DDL
against `platform.prefix_tags` / `platform.prefix_tag_snapshots`.

#### Scenario: Plugin emits snapshot payload only

- **WHEN** a prefix-tag source plugin completes a successful collection
- **THEN** it submits a versioned prefix-tag snapshot payload via the standard
  plugin result / action-result path
- **AND** core performs snapshot promotion and trie invalidation
