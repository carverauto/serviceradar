# build-web-ui Specification (Delta)

## ADDED Requirements

### Requirement: Catalog-driven integration source options

The Integrations settings UI SHALL present product integration types from the
runtime integration catalog (approved package descriptors) rather than a
hard-coded exclusive list of product names in the LiveView template, for any
source that is plugin-owned. Built-in transitional types MAY remain until
migrated.

#### Scenario: NetBox appears only when its package is approved

- **WHEN** no approved package claims NetBox credentials or prefix-tag sources
- **THEN** the Integrations UI does not require a hard-coded NetBox-only create
  path that depends on core `NetboxImportWorker`
- **WHEN** an approved NetBox package is present
- **THEN** operators can configure it from catalog-supplied labels and schema

### Requirement: Prefix Tags source tabs are data-driven

The Prefix Tags settings UI SHALL list imported sources from active prefix-tag
snapshots (and catalog labels when available), not from a fixed hard-coded set
of product names alone. The `manual` source SHALL remain the only operator-
writable tab for v1 of this change.

#### Scenario: New plugin source appears without UI code change

- **WHEN** a new approved plugin promotes an active snapshot for source
  `infoblox` (example)
- **THEN** the Prefix Tags UI can surface that source as a read-only tab
  without a core HEEx edit that hard-codes `infoblox`
