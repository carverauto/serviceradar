## ADDED Requirements
### Requirement: Plugin Package Blobs Are Retained By Policy
The system SHALL clean up plugin package blobs from the configured plugin storage backend according to a configurable, reference-aware retention policy. The policy SHALL protect staged and approved package blobs and SHALL protect any package blob referenced by plugin assignments or target policies.

#### Scenario: Unreferenced revoked package blob is removed
- **GIVEN** a plugin package has status `revoked`
- **AND** no plugin assignment or target policy references the package
- **AND** the package blob is older than the configured orphan grace period
- **WHEN** the plugin blob retention worker runs in destructive mode
- **THEN** the worker deletes the package blob from the configured storage backend
- **AND** records the deleted key in the cleanup summary

#### Scenario: Active plugin package blob is protected
- **GIVEN** a plugin package has status `approved`
- **AND** an agent assignment references the package
- **WHEN** the plugin blob retention worker runs
- **THEN** the worker does not delete the package blob
- **AND** reports the blob as protected in the cleanup summary

### Requirement: Plugin Storage Supports Backend Inventory
The plugin storage abstraction SHALL provide an inventory operation that lists plugin blob metadata for both filesystem and JetStream backends without loading full package payloads into memory.

#### Scenario: JetStream plugin blob inventory
- **GIVEN** plugin storage is configured with the JetStream backend
- **WHEN** the retention planner requests plugin blob inventory
- **THEN** storage lists matching `plugins/` object keys and metadata
- **AND** the planner can identify orphaned keys that are not referenced by plugin package records
