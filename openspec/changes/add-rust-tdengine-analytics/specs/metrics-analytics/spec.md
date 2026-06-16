## ADDED Requirements

### Requirement: Rust analytics service consumes metrics from JetStream
The system SHALL provide a Rust analytics service that consumes canonical metric
envelopes from NATS JetStream pull durables and SHALL NOT receive metrics
directly from collectors, agents, or gateways outside JetStream.

#### Scenario: Metrics enter through JetStream only
- **GIVEN** an agent or gateway emits metric data
- **WHEN** the analytics service processes that data
- **THEN** the data has first been persisted to a JetStream stream
- **AND** the analytics service consumes it from a durable consumer

#### Scenario: Direct database bypass is rejected
- **WHEN** a metric source attempts to write raw metric points directly to TDengine
- **THEN** that path is outside the supported architecture
- **AND** it SHALL NOT be used as the production ingestion path

#### Scenario: Complementary stores receive mirrored metrics
- **GIVEN** TDengine, Iggy, or Iceberg benchmark mode is enabled
- **WHEN** the analytics service writes to the complementary store
- **THEN** it writes data consumed or replayed from JetStream
- **AND** it does not require agents or gateways to bypass JetStream

### Requirement: Analytics partitions have single-owner processing
The analytics service SHALL assign metric series to deterministic partitions and
SHALL ensure only one live worker owns and pulls each partition durable at a
time.

#### Scenario: Worker acquires a partition lease
- **GIVEN** a partition durable is unowned
- **WHEN** a worker successfully acquires the NATS KV lease for that partition
- **THEN** that worker becomes the only worker allowed to pull the durable

#### Scenario: Worker dies and another resumes
- **GIVEN** a worker owns a partition and stops renewing its lease
- **WHEN** the lease expires
- **THEN** another worker MAY acquire the lease
- **AND** it resumes from the same durable checkpoint

### Requirement: TDengine raw metric writes use trusted Rust access
The analytics service SHALL write raw high-rate metrics to TDengine through a
trusted Rust native or WebSocket-capable client path selected by benchmark and
operational review.

#### Scenario: REST write path is not selected
- **WHEN** the analytics service writes raw metrics to TDengine
- **THEN** it SHALL NOT use TDengine REST writes as the production or primary
  benchmark path

#### Scenario: Write benchmark uses ServiceRadar fixtures
- **GIVEN** captured ServiceRadar `MetricBatch` fixtures
- **WHEN** TDengine write performance is measured
- **THEN** the benchmark expands those fixtures into the candidate TDengine
  row/tag model
- **AND** reports sustained rows/sec and latency using that shape

### Requirement: Anomaly and capacity outputs remain observable through JetStream
The analytics service SHALL emit anomaly and capacity outputs as sparse events
or findings through JetStream-backed paths so existing CNPG observability
surfaces can ingest and display them.

#### Scenario: Anomaly state change emitted
- **WHEN** the analytics service detects an anomaly open or clear transition
- **THEN** it emits a sparse finding/event to JetStream
- **AND** the existing observability ingestion path can persist it for UI display

#### Scenario: Clean samples stay internal
- **WHEN** metric samples do not produce anomaly or capacity state changes
- **THEN** the analytics service SHALL NOT emit one finding per clean sample

### Requirement: Analytics state survives worker restart
The analytics service SHALL checkpoint per-partition anomaly and capacity state
so a replacement worker can resume without reprocessing clean state from the
beginning of retention.

#### Scenario: Replacement worker restores state
- **GIVEN** a worker has checkpointed partition state
- **WHEN** a replacement worker acquires that partition
- **THEN** it restores the checkpoint before processing new messages
- **AND** avoids duplicate anomaly state transitions for already-acknowledged
  samples
