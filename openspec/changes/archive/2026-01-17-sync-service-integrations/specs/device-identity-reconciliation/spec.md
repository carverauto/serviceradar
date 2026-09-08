## ADDED Requirements
### Requirement: Sync Updates Routed Through DIRE per Tenant
The system SHALL route sync device updates through DIRE with tenant scoping before persisting canonical device identities.

#### Scenario: Tenant-scoped identity resolution for sync updates
- **GIVEN** a batch of sync device updates for tenant-A
- **WHEN** the updates are ingested
- **THEN** DIRE resolves identities within tenant-A scope
- **AND** no identifiers are matched across tenants
