## ADDED Requirements

### Requirement: Result parity is proven before a dataset is cut over
The system SHALL cut a dataset's reads over to the warehouse only after every query shape the product sends for that dataset has been executed by both SQL dialects over the same synthetic rows and the result sets compared.
The inventory of query shapes is derived from the source, and a difference is either fixed or recorded as a named, reasoned deviation.

#### Scenario: A translation is plausible and wrong
- **WHEN** a dataset's counter `rate` compiles on the warehouse to an aggregate of the stored cumulative values
- **THEN** the parity comparison fails, because the two backends return different values for the same rows
- **AND** the dataset is not added to any shipped cutover list until the comparison passes

#### Scenario: A new chart query is added
- **WHEN** a change introduces a chart query against a cut-over dataset that is absent from the inventory
- **THEN** a repository test fails until the query shape is inventoried and compared

#### Scenario: Adversarial rows
- **WHEN** the comparison runs for a counter dataset
- **THEN** its fixture includes a 32-bit wrap, a counter reset, a missed poll, a NULL dimension and a limit smaller than the bucket count
- **AND** all fixture values are synthetic

### Requirement: All append-only telemetry is warehouse-eligible
The system SHALL provide a warehouse table, an EventWriter destination on the JetStream-first single-owner path, SRQL dataset routing and warehouse-side rollups for flows, scalar metrics, logs, events, OTel metric points and definitions, OTel traces and spans, sysmon CPU, memory, disk and process metrics, MTR traces and hops, BMP routing events and service status history.

#### Scenario: A dataset is shadow-written
- **WHEN** StarRocks is enabled and a dataset is listed for shadowing
- **THEN** its telemetry is persisted to the warehouse by EventWriter from JetStream
- **AND** no collector, agent or UI process writes that dataset to the warehouse directly

#### Scenario: StarRocks is not enabled
- **WHEN** an installation leaves StarRocks off
- **THEN** every dataset is stored and served from CNPG exactly as before this change

### Requirement: CNPG holds current state, not telemetry history
The system SHALL keep in CNPG the data that is updated in place under transactional guarantees, namely inventory and identity, credentials, RBAC and configuration, alert and rule state, jobs, and the enrichment caches the warehouse joins through its read-only catalog, and SHALL treat every append-only telemetry dataset as eligible for retirement from CNPG.

#### Scenario: Warehouse query needs current state
- **WHEN** an authorized analytics query needs a device name, exporter name, prefix tag or process identity
- **THEN** it joins the CNPG relation through the read-only catalog
- **AND** that relation is not copied into the warehouse as telemetry

### Requirement: Telemetry is retired from CNPG by explicit one-way steps
The system SHALL stop CNPG writes for a dataset only by an explicit per-dataset operator setting, SHALL refuse that setting unless the dataset's reads are cut over, its non-UI consumer inventory is recorded complete with every consumer migrated, and the declared soak period has elapsed since cutover with no reader errors, and SHALL drop the dataset's CNPG storage only by a separate, reviewed migration after a distinct, shorter retirement hold with writes off.
The soak precedes write retirement because stopping writes is the first irreversible step; the retirement hold precedes the storage drop. Neither step is implied by the other, by a cutover, or by an upgrade.

#### Scenario: Writes are disabled for a dataset still read from CNPG
- **WHEN** an operator disables CNPG writes for a dataset that is not in the cutover list
- **THEN** startup refuses the configuration with a reason
- **AND** CNPG writes for that dataset continue

#### Scenario: Writes are disabled before the soak has elapsed
- **WHEN** an operator disables CNPG writes for a cut-over dataset whose declared soak period has not elapsed, or has recorded reader errors
- **THEN** startup refuses the configuration with a reason naming the unmet condition
- **AND** CNPG writes for that dataset continue

#### Scenario: Reads are cut over but writes are not retired
- **WHEN** a dataset is cut over and its CNPG writes remain enabled
- **THEN** removing it from the cutover list returns its reads to CNPG with no data gap
- **AND** this does not apply to flows, whose reads are refused rather than returned to CNPG

#### Scenario: A non-UI consumer still reads the CNPG table
- **WHEN** an alert rule, promotion rule, forecast or backfill still reads a dataset's CNPG relation
- **THEN** the dataset's consumer inventory is not complete, and startup refuses to disable its CNPG writes
- **AND** the consumer inventory is established by searching for the relation and its aggregates, not for a known module

#### Scenario: Storage is dropped
- **WHEN** CNPG writes for a dataset have been off for the declared retirement hold with no reader errors
- **THEN** a separate migration may drop its hypertable, continuous aggregates and policies
- **AND** the migration is not part of the release that disabled the writes

### Requirement: Warehouse maintenance is bounded by the smallest supported node
The system SHALL perform warehouse maintenance that moves data in units sized so that a single statement stays within the memory of the smallest supported compute node, SHALL resume at that unit, and SHALL lengthen its retry interval on a memory-limit error instead of retrying at the normal rate.
The transaction that holds the warehouse migration lock SHALL clear Postgres `statement_timeout` and `lock_timeout` for itself only, so waiting for a long maintenance run is not cancelled (issue #4525).

#### Scenario: A legacy table is rebuilt on a small warehouse
- **WHEN** a table large enough that one day exceeds a compute node's memory is rebuilt onto daily partitions
- **THEN** no statement copies or joins more than one bounded unit of it
- **AND** no compute node is terminated for memory by the rebuild

#### Scenario: A unit fails for lack of memory
- **WHEN** a maintenance statement fails with the warehouse's memory-limit error
- **THEN** the next attempt waits substantially longer than a normal retry
- **AND** the log states how many units remain

#### Scenario: A replica waits for the migration lock behind a long rebuild
- **WHEN** one replica holds the warehouse migration lock for longer than the database's configured `statement_timeout` or `lock_timeout`
- **THEN** the waiting replica's lock transaction is not cancelled by either timeout, because it clears both for itself
- **AND** the timeouts of every other transaction are unchanged

### Requirement: Log search behaviour is stated from measurement
The system SHALL document free-text log search over warehouse retention according to measured support on the deployed StarRocks profile, and SHALL NOT present search over long retention as indexed unless an index type supporting it is verified available in that profile.

#### Scenario: Inverted index is unavailable in shared-data mode
- **WHEN** measurement shows the profile does not support the index type
- **THEN** log search is documented as bounded by time range and structured filters
- **AND** the UI does not imply otherwise
