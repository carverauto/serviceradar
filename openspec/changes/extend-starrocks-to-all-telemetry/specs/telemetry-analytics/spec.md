## ADDED Requirements

### Requirement: Result parity is proven before a warehouse reader ships
The system SHALL ship a warehouse implementation of a reader only after every query shape that reader sends has been executed by both SQL dialects over the same synthetic rows and the result sets compared.
The inventory of query shapes is derived from the source, and a difference is either fixed or recorded as a named, reasoned deviation.

#### Scenario: A translation is plausible and wrong
- **WHEN** a dataset's counter `rate` compiles on the warehouse to an aggregate of the stored cumulative values
- **THEN** the parity comparison fails, because the two backends return different values for the same rows
- **AND** the warehouse implementation of that reader does not ship until the comparison passes

#### Scenario: A new chart query is added
- **WHEN** a change introduces a chart query against a warehouse dataset that is absent from the inventory
- **THEN** a repository test fails until the query shape is inventoried and compared

#### Scenario: Adversarial rows
- **WHEN** the comparison runs for a counter dataset
- **THEN** its fixture includes a 32-bit wrap, a counter reset, a missed poll, a NULL dimension and a limit smaller than the bucket count
- **AND** all fixture values are synthetic

### Requirement: All append-only telemetry is warehouse-eligible
The system SHALL provide a warehouse table, an EventWriter destination on the JetStream-first single-owner path, SRQL dataset routing and warehouse-side rollups for flows, scalar metrics, logs, events, OTel metric points and definitions, OTel traces and spans, sysmon CPU, memory, disk and process metrics, MTR traces and hops, BMP routing events and service status history.

#### Scenario: StarRocks is enabled
- **WHEN** StarRocks is enabled
- **THEN** every append-only telemetry dataset is persisted to the warehouse by EventWriter from JetStream
- **AND** no collector, agent or UI process writes any dataset to the warehouse directly

#### Scenario: StarRocks is not enabled
- **WHEN** an installation leaves StarRocks off
- **THEN** every dataset is stored and served from CNPG exactly as before this change

### Requirement: CNPG holds current state, not telemetry history
The system SHALL keep in CNPG the data that is updated in place under transactional guarantees, namely inventory and identity, credentials, RBAC and configuration, alert and rule state, jobs, and the enrichment caches the warehouse joins through its read-only catalog, and SHALL keep append-only telemetry out of CNPG whenever StarRocks is enabled.

#### Scenario: Warehouse query needs current state
- **WHEN** an authorized analytics query needs a device name, exporter name, prefix tag or process identity
- **THEN** it joins the CNPG relation through the read-only catalog
- **AND** that relation is not copied into the warehouse as telemetry

### Requirement: An enabled warehouse is the only telemetry store
The system SHALL, when StarRocks is enabled, persist every append-only telemetry dataset only to the warehouse, with no CNPG dual-write, no per-dataset shadow or cutover list and no soak period, and SHALL serve every telemetry read from the warehouse.
A warehouse write failure SHALL fail the JetStream acknowledgement so the message is redelivered, never fall back to a CNPG write. A reader that has no warehouse implementation yet SHALL report its data as unavailable while StarRocks is enabled; it SHALL NOT query the CNPG table, which receives no new rows. Existing CNPG telemetry storage SHALL be dropped only by a separate, reviewed migration, never implied by enabling the warehouse.

#### Scenario: Telemetry is written with StarRocks enabled
- **WHEN** EventWriter persists a flow, metric, log, event, OTel, sysmon, MTR, BMP or service-status batch with StarRocks enabled
- **THEN** the rows are written to the warehouse
- **AND** no row is written to the dataset's CNPG hypertable

#### Scenario: The warehouse write fails
- **WHEN** a warehouse load fails
- **THEN** the batch is not acknowledged and JetStream redelivers it
- **AND** the batch is not written to CNPG instead

#### Scenario: A reader has not been moved yet
- **WHEN** a page, card or background job reads a telemetry dataset that has no warehouse implementation while StarRocks is enabled
- **THEN** it reports the data as unavailable with StarRocks enabled
- **AND** it does not query the CNPG table, whose contents stopped at the moment the warehouse was enabled

#### Scenario: StarRocks is disabled again
- **WHEN** an operator disables StarRocks on an installation that ran with it enabled
- **THEN** EventWriter resumes writing telemetry to CNPG
- **AND** the telemetry written while the warehouse was enabled is not in CNPG, and the operator documentation says so

#### Scenario: CNPG telemetry storage is dropped
- **WHEN** an installation has run with StarRocks enabled and no remaining CNPG telemetry reader
- **THEN** a separate, reviewed migration may drop the dataset's hypertable, continuous aggregates and policies
- **AND** enabling the warehouse does not drop them

### Requirement: MTR traces and hops reach the warehouse through JetStream
The system SHALL publish every MTR trace result, scheduled, on-demand, bulk and ad-hoc, from core to a JetStream subject, and SHALL persist traces and hops by EventWriter from that subject: to the warehouse when StarRocks is enabled, and to CNPG otherwise.
Core SHALL NOT write MTR traces or hops to either store directly. MTR hop rollups SHALL aggregate loss with `loss_ratio(sent, received)` and latency with `wavg(avg_us, received)`, never with an average of per-hop percentages or means.

#### Scenario: A scheduled MTR check reports
- **WHEN** the gateway forwards an agent's `mtr_traces` results to core
- **THEN** core publishes each trace to the MTR JetStream subject
- **AND** the trace and its hops are stored by EventWriter, not by the core status path

#### Scenario: MTR readers with StarRocks enabled
- **WHEN** the dashboard MTR cards, the diagnostics trace list, trace detail, Compare page or device MTR tab load with StarRocks enabled
- **THEN** they read MTR traces and hops from the warehouse

#### Scenario: MTR loss across hops with unequal probe counts
- **WHEN** a rollup aggregates destination loss over hops that sent different numbers of probes
- **THEN** it reports the summed-probe loss ratio, not the mean of the hops' loss percentages

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
