## ADDED Requirements

### Requirement: Iceberg raw metric sink is evaluated as a lakehouse tier
The system SHALL evaluate an Iceberg-backed raw metric sink for long-retention
history, replay, and offline analytics using captured ServiceRadar metric
fixtures.

#### Scenario: Sink writes partition-aligned files
- **GIVEN** captured ServiceRadar metric fixtures
- **WHEN** the Iceberg sink benchmark writes raw metrics
- **THEN** it writes partition-aligned files with explicit file size targets
- **AND** reports commit cadence, file count, bytes written, and rows written

#### Scenario: Maintenance cost is included
- **WHEN** Iceberg benchmark results are reported
- **THEN** the report includes compaction, manifest rewrite, and snapshot
  expiration costs
- **AND** it does not count only append throughput as the total operating cost

### Requirement: Iceberg-only serving requires query latency proof
The system SHALL NOT select Iceberg as the only metric serving backend unless it
meets ServiceRadar query latency and freshness requirements for recent metric
queries.

#### Scenario: Latest metric query benchmark
- **GIVEN** an Iceberg-backed metric dataset
- **WHEN** SRQL executes a latest metric query for a device/resource
- **THEN** the benchmark records latency against the required UI/SRQL SLO

#### Scenario: Bucketed graph query benchmark
- **GIVEN** an Iceberg-backed metric dataset
- **WHEN** SRQL executes a last-hour bucketed graph query
- **THEN** the benchmark records latency and verifies result parity with the
  captured fixture model

### Requirement: Hot serving and lakehouse tiers can coexist
The system SHALL allow a TSDB for hot metric serving and Iceberg for long-retention
raw history when one store cannot satisfy both low-latency serving and cheap
large-scale retention.

#### Scenario: Recent query uses serving store
- **GIVEN** hot serving plus Iceberg tiers are enabled
- **WHEN** SRQL executes a recent metric query
- **THEN** it MAY route to the serving store

#### Scenario: Long-retention query uses Iceberg
- **GIVEN** hot serving plus Iceberg tiers are enabled
- **WHEN** SRQL executes a long-retention historical scan
- **THEN** it MAY route to Iceberg
