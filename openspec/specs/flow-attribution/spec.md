# flow-attribution Specification

## Purpose
Ingestion of process attribution observations via JetStream into StarRocks and background correlation stamping on flow records.

## Requirements

### Requirement: Attribution Observations Flow Through JetStream Into StarRocks
Process attribution observations SHALL be published to JetStream on `flows.attribution.observations` and persisted by an EventWriter processor into the StarRocks table `flow_process_attribution_observations`. Core MUST NOT write observations directly to CNPG or StarRocks.

#### Scenario: Observation batch is admitted
- **GIVEN** an agent delivers a flow-attribution event batch from its netprobe sidecar
- **WHEN** core admits the batch
- **THEN** it publishes the observations on `flows.attribution.observations`
- **AND** EventWriter persists them to `flow_process_attribution_observations`
- **AND** no CNPG table receives the observations

### Requirement: Observation Storage Has No Row-Level Churn
The observation table SHALL be an append-only StarRocks Duplicate Key table partitioned by day on `observed_at`. Observations MUST NOT be updated or deleted row by row; expiry MUST happen by dropping whole partitions. Retention SHALL default to 30 days, SHALL be operator-configurable through the warehouse Data retention setting, and MUST NOT be set below 1 day.

#### Scenario: Old observations expire
- **GIVEN** observations older than the retained span
- **WHEN** partition retention runs
- **THEN** their partitions are dropped
- **AND** no row-level DELETE or UPDATE is issued against the table

#### Scenario: Default attribution retention
- **GIVEN** a new installation with no stored retention setting for the attribution dataset and no seed override
- **WHEN** retention is applied
- **THEN** the observation table keeps 30 daily partitions

#### Scenario: Repeated observation of the same socket
- **GIVEN** the same attribution key is observed many times within the window
- **WHEN** the observations are persisted
- **THEN** each is appended as a new row
- **AND** correlation still selects the newest qualifying observation for that key and rank

### Requirement: Correlation Runs In The Warehouse
The correlator SHALL match recent unattributed flows to observations in a single StarRocks statement per pass, preserving every candidate family and precedence rank of *Correlation Is Protocol-Aware And Exact-First*, and SHALL publish matches on `events.flow.attribution` for EventWriter to apply as a partial update of `ocsf_network_activity`. Workload identity MUST be enriched from CNPG by key for the matched rows only.

#### Scenario: Exact tuple wins in the warehouse
- **GIVEN** an exact tuple observation and a lower-ranked candidate are both eligible for a flow
- **WHEN** the correlator runs its warehouse statement
- **THEN** it selects the exact candidate
- **AND** publishes the stamp on `events.flow.attribution`

#### Scenario: Workload identity is attached without scanning the workload table
- **GIVEN** a pass matches a batch of flows to observations that carry container ids
- **WHEN** the correlator builds the stamps
- **THEN** it looks up workload identity in CNPG only for those matched rows
- **AND** the published stamps carry the workload identity

### Requirement: Attribution Requires StarRocks
When StarRocks is not configured, flow process attribution SHALL be disabled: observations MUST NOT be stored in CNPG, the correlator MUST NOT run, and the attribution health surface MUST report that StarRocks is required.

#### Scenario: Deployment without StarRocks
- **GIVEN** a deployment with no StarRocks warehouse configured
- **WHEN** an agent delivers flow-attribution observations
- **THEN** core does not persist them anywhere
- **AND** the attribution health surface reports `attribution_disabled: starrocks_required`

### Requirement: Correlator Health Is Observable
The correlator SHALL emit pass duration, flows read, matches by strategy, stamped count, observation lag, observation ingest rate and live partition count as metrics through the JetStream metrics pipeline.

#### Scenario: A pass completes
- **WHEN** a correlation pass finishes, successfully or not
- **THEN** its duration, outcome and counts are published as metrics on JetStream
