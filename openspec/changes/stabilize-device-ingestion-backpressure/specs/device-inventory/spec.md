## ADDED Requirements
### Requirement: Device inventory stays consistent with CNPG during ingest backpressure
The system SHALL keep registry device counts within a configured tolerance of CNPG and emit an explicit alert when drift exceeds that tolerance during high-volume ingest.

#### Scenario: Faker-scale ingest completes without registry/CNPG drift
- **WHEN** faker generates approximately 50,000 devices and stats aggregation runs while AGE graph writes are backpressured
- **THEN** registry total_devices matches CNPG counts within the configured tolerance (for example, within 1%) and does not silently fall below the expected scale.

#### Scenario: Drift triggers alert with context
- **WHEN** registry total_devices deviates from CNPG beyond the tolerance
- **THEN** the system emits an alert/log that includes raw/processed counts and skipped_non_canonical figures so operators can triage the discrepancy.

### Requirement: Service-device capabilities survive graph degradation
The system SHALL persist and surface capability snapshots for service devices (for example, ICMP for `k8s-agent`) even when AGE graph writes are delayed or failing, and SHALL provide replay or visibility for any skipped batches.

#### Scenario: ICMP capability visible under AGE backlog
- **WHEN** ICMP results arrive for `k8s-agent` while the AGE graph queue is saturated or timing out
- **THEN** the ICMP capability snapshot is recorded and retrievable via the registry/UI within the same ingest pass, independent of graph success.

#### Scenario: Recover skipped capability batches
- **WHEN** a capability or device-update batch is skipped or delayed because graph dispatch is offline
- **THEN** the system records the skipped batch and replays or exposes it for operator retry so capabilities and devices are not permanently dropped.
