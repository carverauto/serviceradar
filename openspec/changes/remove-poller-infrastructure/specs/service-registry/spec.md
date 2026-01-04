## RENAMED Requirements
- FROM: `### Requirement: Poller status updates preserve registration metadata`
- TO: `### Requirement: Gateway status updates preserve registration metadata`
- FROM: `### Requirement: Registration writes remain authoritative for registration metadata`
- TO: `### Requirement: Gateway registration writes remain authoritative for registration metadata`

## MODIFIED Requirements
### Requirement: Gateway status updates preserve registration metadata
When the system records gateway operational state (e.g., `is_healthy`, `last_seen`), it SHALL NOT overwrite gateway registration metadata (`component_id`, `registration_source`, `status`, `spiffe_identity`, `metadata`, `created_by`, `first_registered`, and `first_seen`).

#### Scenario: Explicitly registered gateway retains metadata after status update
- **GIVEN** gateway `edge-gateway-01` is explicitly registered with non-default `component_id`, `registration_source`, `spiffe_identity`, and `metadata`
- **WHEN** the gateway reports status updates that update `last_seen` and/or `is_healthy`
- **THEN** the stored registration metadata remains unchanged
- **AND** only operational fields (such as `last_seen`, `is_healthy`, `updated_at`) are updated

#### Scenario: Status updates do not clear first-seen timestamps
- **GIVEN** gateway `edge-gateway-01` has a non-null `first_registered` and `first_seen`
- **WHEN** a status update occurs where the caller does not provide `first_seen`
- **THEN** `first_registered` and `first_seen` remain unchanged

### Requirement: Gateway registration writes remain authoritative for registration metadata
When the system performs an explicit gateway registration or metadata update (e.g., edge onboarding), it SHALL update gateway registration metadata and SHALL NOT be overwritten by subsequent status/heartbeat writes.

#### Scenario: Explicit registration after implicit status insert updates metadata
- **GIVEN** gateway `edge-gateway-01` first appears via an implicit status insert (defaults applied)
- **WHEN** an explicit registration is later performed with non-default identity/provenance metadata
- **THEN** the gateway record reflects the explicit registration metadata after registration completes
- **AND** subsequent status updates preserve those values
