## MODIFIED Requirements
### Requirement: Sysmon Metrics Ingestion

Sysmon metrics pushed via gRPC SHALL be routed to core ingestion and stored in tenant-scoped hypertables.

#### Scenario: Sysmon metrics forwarded to core
- **WHEN** an edge agent emits sysmon metrics
- **AND** the payload is sent with `source=sysmon-metrics`
- **THEN** the gateway forwards the payload to core ingestion
- **AND** core writes CPU, CPU cluster, memory, disk, and process metrics into tenant schemas

#### Scenario: Sysmon payload size tolerance
- **WHEN** a sysmon metrics payload exceeds the standard status size limit
- **THEN** the gateway accepts the larger payload up to a configurable limit (per-tenant) with a documented default of 15MB
- **AND** oversized payloads are rejected explicitly
