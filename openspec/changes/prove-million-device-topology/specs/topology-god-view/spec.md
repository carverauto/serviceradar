## ADDED Requirements

### Requirement: Million-device acceptance uses the actual product ingestion path
The topology workstream SHALL demonstrate one million persisted invented devices
and at least two million canonical relations in the authenticated product, using
SNMP-derived overlays from JetStream/EventWriter and a hardware-WebGPU browser
with animated edges, before declaring the end-to-end scale proof complete.

#### Scenario: Distinguish focused tests from end-to-end acceptance
- **WHEN** a browser fixture supplies encoded geometry with mocked channel or overlay responses
- **THEN** it SHALL remain focused renderer evidence
- **AND** it SHALL NOT close the real-ingestion acceptance task

#### Scenario: Hardware performance with active traffic
- **WHEN** the ingested million-device workload is explored with traffic enabled
- **THEN** first usable frame SHALL be at most 3 seconds, pan/zoom at least 30 FPS, hover/select below 100 milliseconds, and local tile fetch plus decode p95 at most 200 milliseconds
- **AND** the report SHALL separately name topology population, active telemetry population, cadence, ingest backlog and freshness
- **AND** it SHALL verify initial camera coverage, aggregate totals, bounded detail, cache reuse and zero geometry refetch from telemetry updates
