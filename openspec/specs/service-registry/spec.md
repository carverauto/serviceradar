# service-registry Specification

## Purpose
TBD - created by archiving change fix-poller-status-metadata-clobber. Update Purpose after archive.
## Requirements
### Requirement: Poller status updates preserve registration metadata
When the system records poller operational state (e.g., `is_healthy`, `last_seen`), it SHALL NOT overwrite poller registration metadata (`component_id`, `registration_source`, `status`, `spiffe_identity`, `metadata`, `created_by`, `first_registered`, and `first_seen`).

#### Scenario: Explicitly registered poller retains metadata after status update
- **GIVEN** poller `edge-poller-01` is explicitly registered with non-default `component_id`, `registration_source`, `spiffe_identity`, and `metadata`
- **WHEN** the poller reports status updates that update `last_seen` and/or `is_healthy`
- **THEN** the stored registration metadata remains unchanged
- **AND** only operational fields (such as `last_seen`, `is_healthy`, `updated_at`) are updated

#### Scenario: Status updates do not clear first-seen timestamps
- **GIVEN** poller `edge-poller-01` has a non-null `first_registered` and `first_seen`
- **WHEN** a status update occurs where the caller does not provide `first_seen`
- **THEN** `first_registered` and `first_seen` remain unchanged

### Requirement: Registration writes remain authoritative for registration metadata
When the system performs an explicit poller registration or metadata update (e.g., edge onboarding), it SHALL update poller registration metadata and SHALL NOT be overwritten by subsequent status/heartbeat writes.

#### Scenario: Explicit registration after implicit status insert updates metadata
- **GIVEN** poller `edge-poller-01` first appears via an implicit status insert (defaults applied)
- **WHEN** an explicit registration is later performed with non-default identity/provenance metadata
- **THEN** the poller record reflects the explicit registration metadata after registration completes
- **AND** subsequent status updates preserve those values

