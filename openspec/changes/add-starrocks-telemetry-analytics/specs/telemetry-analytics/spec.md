## ADDED Requirements

### Requirement: StarRocks is the optional telemetry warehouse switch
The system SHALL treat StarRocks as an optional warehouse for flows, scalar metrics, logs and event history, SHALL keep NetFlow collection independently gated, and SHALL require StarRocks when NetFlow collection is enabled.

#### Scenario: Install without StarRocks
- **WHEN** an operator leaves StarRocks analytics disabled
- **THEN** NetFlow collection cannot be enabled
- **AND** logs and other remaining telemetry persist to CNPG hypertables
- **AND** Helm does not fail closed for the missing warehouse

#### Scenario: NetFlow without StarRocks is refused
- **WHEN** an operator enables NetFlow collection without enabling StarRocks analytics
- **THEN** chart rendering fails closed
- **AND** the collector workload is not deployed

#### Scenario: StarRocks without NetFlow still warehouses other telemetry
- **WHEN** an operator enables StarRocks analytics and leaves NetFlow collection disabled
- **THEN** the flow collector is not deployed
- **AND** EventWriter shadows scalar metrics, logs and event history into StarRocks
- **AND** CNPG remains authoritative for inventory, configuration, credentials and current alert state
- **AND** serving still follows per-dataset cutover rather than implying every dataset has switched

#### Scenario: StarRocks with NetFlow
- **WHEN** an operator enables StarRocks analytics and NetFlow collection
- **THEN** the flow collector is deployed
- **AND** EventWriter shadows flows together with scalar metrics, logs and event history into StarRocks

### Requirement: Explicit analytics deployment profiles
The system SHALL provide opt-in StarRocks shared-data analytics with dedicated object storage and a shared-nothing profile with durable local storage, while retaining CNPG for control-plane state and unmigrated datasets.

#### Scenario: OSS deployment without object storage
- **WHEN** an operator selects shared-nothing analytics
- **THEN** the installation uses durable BE storage without requiring an object store
- **AND** CNPG remains authoritative for inventory, configuration, credentials and current state

#### Scenario: Hosted shared-data recovery
- **WHEN** a CN cache is lost
- **THEN** durable data remains in the configured analytics storage volume
- **AND** recovery preserves FE metadata and reports readiness only after functional checks
- **AND** cache recovery latency is measured rather than assumed instantaneous

### Requirement: JetStream first and single persistence ownership
The system SHALL persist migrated telemetry through JetStream and the EventWriter owner, with bounded per-dataset batching and independent flow demand, and SHALL NOT introduce collector-to-database telemetry writes or a competing persistence consumer.

#### Scenario: Slow destination applies backpressure
- **WHEN** a StarRocks load is delayed
- **THEN** row, byte, age and in-flight limits bound EventWriter resource use
- **AND** queue age and JetStream retention risk are observable
- **AND** unrelated ingestion demand domains remain independently bounded

#### Scenario: Shadow destination partially succeeds
- **WHEN** one required destination commits and another fails
- **THEN** the owner retains per-destination progress and retries missing work with stable identities
- **AND** no message is reported fully persisted before all required destinations satisfy the delivery contract

### Requirement: Replay-safe persistence and visible load failures
The system SHALL preserve stable record identity across retry, batch regrouping, crash recovery and historical overlap, and SHALL acknowledge telemetry only after confirmed durable visible persistence or a durable, observable quarantine disposition.

#### Scenario: Lost load response after commit
- **WHEN** the client loses the response to a committed Stream Load
- **THEN** it reconciles the original load identity before completing acknowledgement
- **AND** redelivery does not increase logical record counts or traffic totals

#### Scenario: Expired load label
- **WHEN** a committed message is replayed after StarRocks load-label retention expires
- **THEN** record-level idempotency still prevents duplicate analytical totals

#### Scenario: Publish timeout or rejected rows
- **WHEN** the response reports publish timeout, an existing label, or unexpected filtered rows
- **THEN** HTTP success alone does not produce a successful persistence acknowledgement
- **AND** status reconciliation or durable quarantine exposes the unresolved outcome

### Requirement: Mutable enrichment survives migration
The system SHALL retain flow attribution and enrichment semantics through versioned updates delivered via JetStream to EventWriter, with stable flow identity and ordering that prevents stale updates or raw redelivery from erasing newer enrichment.

#### Scenario: Attribution arrives after raw flow
- **WHEN** a newer attribution update arrives for an existing flow
- **THEN** the persisted flow exposes the updated provenance without changing its traffic totals
- **AND** a later replay of the original flow cannot erase the attribution

#### Scenario: Older update follows a retraction
- **WHEN** an attribution retraction is followed by an older update
- **THEN** the current retracted state remains authoritative

#### Scenario: Current-state attribution is queried on StarRocks history
- **WHEN** an authorized caller requests live process correlation or prefix-tag enrichment on StarRocks-served flows
- **THEN** the query joins local flow facts to allowlisted CNPG current-state tables through the JDBC catalog
- **AND** the correlator does not write StarRocks
- **AND** application code does not merge CNPG attribution rows with StarRocks flows itself

### Requirement: Dataset retention and coverage contracts
The system SHALL expose configurable raw and aggregate retention by dataset, default hosted flows, logs, events and alert history to 365 days, allow longer configured retention, and distinguish durable retention from local cache residency.

#### Scenario: History exceeds local cache
- **WHEN** retained history is absent from local shared-data cache
- **THEN** the query can access durable remote history under the same authorized query contract
- **AND** it does not claim the data has expired merely because of a cache miss

#### Scenario: Expiry encounters protected migration history
- **WHEN** an expiry task reaches data protected by an active backfill, hold or rollback boundary
- **THEN** deletion is deferred with an observable reason
- **AND** late replay cannot silently resurrect history already expired by policy

### Requirement: Guarded dataset cutover and retirement
The system SHALL gate each dataset cutover on complete reader/writer inventory, verified source/target coverage and semantics, scoped query compatibility, measured acceptance and a tested rollback or repair plan.

#### Scenario: Historical source is incomplete
- **WHEN** the old backend lacks history needed for rollback
- **THEN** switching reads back is blocked until coverage is repaired or another approved recovery path exists
- **AND** a healthy deployment or closed PR is not accepted as coverage evidence

#### Scenario: Withdrawn archive resources remain live
- **WHEN** an installation still depends on old archive data or checkpoints
- **THEN** those resources remain intact until separately reviewed migration and restore verification permits retirement

### Requirement: Reproducible performance and recovery acceptance
The system SHALL validate analytics using synthetic, reproducible workloads with declared hardware, versions, concurrency, ingest rate, cache state, correctness ground truth and explicit pass/fail criteria before making capacity claims.

#### Scenario: Benchmark fails the proposed load target
- **WHEN** backlog grows persistently, correctness diverges or an agreed latency gate fails
- **THEN** the candidate workload is reported as failed and cannot justify cutover or a supported-capacity claim

#### Scenario: Recovery drill
- **WHEN** a writer or CN restarts during ingestion or an FE/object-store failure occurs
- **THEN** recovery tests compare final identities and totals against ground truth
- **AND** report restore time, errors and data-loss boundaries against the approved RPO/RTO

### Requirement: Authorized StarRocks reads use the MySQL protocol
The system SHALL execute authorized StarRocks SRQL over a pooled MySQL-protocol connection to the Frontend query port, and SHALL keep EventWriter persistence on Stream Load HTTP.

#### Scenario: Authorized SRQL against a StarRocks-served dataset
- **WHEN** an authorized caller runs SRQL that `Readers.mode_for/1` routes to StarRocks
- **THEN** Elixir submits the compiled SQL on the Frontend MySQL query port
- **AND** it does not use the Frontend HTTP SQL JSON API for that read
- **AND** EventWriter still persists through Stream Load HTTP

#### Scenario: StarRocks query path is unavailable
- **WHEN** the Frontend query port cannot be reached
- **THEN** the query returns an explicit error
- **AND** it does not silently execute the StarRocks SQL against CNPG

### Requirement: Read-only CNPG catalog for current-state joins
The system SHALL provide an opt-in StarRocks JDBC catalog onto CNPG so authorized analytics can join local StarRocks telemetry with allowlisted `platform` current-state dimension tables for flow attribution and enrichment, and SHALL NOT use that catalog as a telemetry serving path or a write path into CNPG.

#### Scenario: Authorized flow query needs current attribution or enrichment
- **WHEN** an authorized caller requests StarRocks-served flows grouped or filtered by live process correlation, prefix tags or current device identity
- **THEN** StarRocks scans the local flow table and joins the allowlisted CNPG current-state table through the JDBC catalog
- **AND** the application does not query CNPG and StarRocks separately and merge rows itself

#### Scenario: Catalog is unavailable
- **WHEN** the JDBC catalog or CNPG reader path fails
- **THEN** the query returns an explicit error
- **AND** it does not silently serve cut-over telemetry from CNPG
- **AND** it does not omit dimension columns without reporting the failure

#### Scenario: Table is not on the allowlist
- **WHEN** a query names a CNPG relation outside the current-state dimension allowlist
- **THEN** compilation or execution rejects the query
- **AND** auth, credential, Oban and telemetry hypertable names remain unreachable through the catalog

#### Scenario: Catalog credentials
- **WHEN** the catalog is provisioned
- **THEN** it uses a least-privilege CNPG reader stored as ServiceRadar-to-self infrastructure secret material
- **AND** the driver JAR is a pinned Bazel artifact rather than an unpinned network download
- **AND** the catalog user cannot INSERT, UPDATE or DELETE CNPG rows
