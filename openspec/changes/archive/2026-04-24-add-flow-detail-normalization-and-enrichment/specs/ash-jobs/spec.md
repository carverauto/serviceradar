## ADDED Requirements

### Requirement: Daily cloud-provider CIDR refresh job
The system SHALL run a daily AshOban job that fetches the configured cloud-provider CIDR dataset (including the rezmoss source), validates and normalizes entries, and promotes a new active snapshot for ingestion enrichment.

#### Scenario: Daily refresh succeeds
- **GIVEN** the external dataset source is reachable and valid
- **WHEN** the daily refresh job runs
- **THEN** a new normalized provider CIDR snapshot is stored
- **AND** that snapshot becomes the active version used by flow ingestion enrichment

#### Scenario: Refresh failure preserves last-known-good snapshot
- **GIVEN** the external dataset source is unavailable or invalid
- **WHEN** the refresh job runs
- **THEN** the active provider CIDR snapshot remains unchanged
- **AND** the job records failure telemetry/logging without breaking ingestion

### Requirement: Weekly IEEE OUI refresh job
The system SHALL run a weekly AshOban job that fetches IEEE `oui.txt`, parses and normalizes OUI prefixes, and promotes a new active OUI snapshot used for MAC vendor enrichment.

#### Scenario: Weekly OUI refresh succeeds
- **GIVEN** the IEEE OUI source is reachable and parseable
- **WHEN** the weekly OUI refresh job runs
- **THEN** a new normalized OUI snapshot is stored in CNPG
- **AND** that snapshot becomes the active version used by ingestion enrichment

#### Scenario: OUI refresh failure preserves last-known-good snapshot
- **GIVEN** the IEEE OUI source is unavailable or malformed
- **WHEN** the weekly OUI refresh job runs
- **THEN** the active OUI snapshot remains unchanged
- **AND** the job records failure telemetry/logging without breaking ingestion
