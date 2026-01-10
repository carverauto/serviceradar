## ADDED Requirements

### Requirement: Oban job failures emit internal OCSF events
The system SHALL record an OCSF Event Log Activity entry in the tenant `ocsf_events` table when a tenant-scoped Oban job exhausts its retry attempts.

#### Scenario: NATS account provisioning job fails after retries
- **GIVEN** the NATS account provisioning job has reached its final retry for a tenant
- **WHEN** the job fails on the last attempt
- **THEN** an `ocsf_events` row SHALL be inserted for the tenant
- **AND** the event SHALL include the job name and attempt count
