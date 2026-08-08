## ADDED Requirements

### Requirement: Tiered metric storage
Raw high-rate metric points SHALL be stored in tiers: a recent window plus rollup
aggregates in CNPG for live graphing and dashboards, and long-retention raw
history in a columnar Delta lakehouse on object storage. The tier boundary SHALL
be a tunable retention window. No metric data depended on by graphing or
forecasting SHALL be lost across the tiers.

#### Scenario: Recent points served from CNPG
- **WHEN** a query requests metric points within the recent retention window
- **THEN** the system SHALL serve them from CNPG raw or CNPG rollups
- **AND** the query SHALL NOT require the lakehouse

#### Scenario: Historical raw served from the lakehouse
- **WHEN** a query requests raw metric points older than the CNPG recent window
- **THEN** the system SHALL serve them from the Delta lakehouse
- **AND** the result SHALL be equivalent to what CNPG would have returned before re-tiering

### Requirement: Durable raw lakehouse ingestion
Raw metric points SHALL be batch-written to the Delta lakehouse from the metrics
JetStream durable, partitioned for query pruning. Write failures SHALL be retried
or dead-lettered and SHALL NOT silently drop points. CNPG raw retention SHALL NOT
be reduced until the lakehouse path is proven at parity for raw-dependent queries.

#### Scenario: Points are durably written to the lakehouse
- **GIVEN** metric points published to the metrics stream
- **WHEN** the Delta writer consumes them
- **THEN** it SHALL batch-write them to the partitioned Delta table
- **AND** a write failure SHALL be retried or dead-lettered, not dropped

#### Scenario: Parity gates CNPG raw reduction
- **GIVEN** the lakehouse write path is running alongside CNPG raw
- **WHEN** raw-dependent query results are compared between CNPG and the lakehouse
- **THEN** CNPG raw retention SHALL only be reduced after parity is demonstrated
