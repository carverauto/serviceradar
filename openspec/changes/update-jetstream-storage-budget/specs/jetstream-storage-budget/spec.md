## ADDED Requirements

### Requirement: EventWriter isolates stream setup failures
EventWriter SHALL keep every successfully set-up consumer running when another consumer's stream cannot be created, updated or placed, and SHALL retry only the failed consumer.
The retry SHALL use exponential backoff capped at 60 seconds. Each failure SHALL emit telemetry naming the stream and the NATS error code, SHALL be logged, and SHALL raise a health event that names the stream.

#### Scenario: One stream cannot be placed
- **GIVEN** EventWriter is configured with `metrics` and `mtr_results` consumers
- **AND** NATS rejects creating `mtr_results` with err 10005 "insufficient storage"
- **WHEN** EventWriter sets up its consumers
- **THEN** the `metrics` consumer SHALL be subscribed and processing messages
- **AND** only the `mtr_results` consumer SHALL be retried with backoff
- **AND** a health event SHALL name `mtr_results` and the NATS error

#### Scenario: The failed stream recovers
- **GIVEN** the `mtr_results` consumer is in backoff after a placement failure
- **WHEN** storage becomes available and the next retry succeeds
- **THEN** the `mtr_results` consumer SHALL start processing
- **AND** the `metrics` consumer SHALL NOT have been restarted

### Requirement: Every created stream reserves a finite size
Every JetStream stream, KV bucket and object store that a ServiceRadar component creates SHALL be created with a positive `max_bytes`.
An unlimited stream consumes placement headroom through stored bytes that reservation accounting and the render-time budget cannot see.

#### Scenario: Previously unlimited stream on a fresh install
- **WHEN** EventWriter creates `trivy_reports` on a fresh install
- **THEN** the stream SHALL have a positive `max_bytes` taken from the chart value

### Requirement: NATS file store is rendered as an exact byte count
The Helm chart SHALL render `max_file_store` as an integer number of bytes.
When `nats.jetstream.maxFileStore` is unset the chart SHALL derive it from `nats.persistence.size` minus `nats.jetstream.filesystemReserve`; when it is set, `G` SHALL mean 10^9 bytes and `Gi` SHALL mean 2^30 bytes, matching NATS.

#### Scenario: Default persistence size
- **GIVEN** `nats.persistence.size` is `30Gi` and `maxFileStore` is unset
- **WHEN** the chart renders the NATS configuration
- **THEN** `max_file_store` SHALL be `31138512896` (29 GiB)

#### Scenario: Explicit decimal override
- **GIVEN** `nats.jetstream.maxFileStore` is `30G`
- **WHEN** the chart renders the NATS configuration
- **THEN** `max_file_store` SHALL be `30000000000`

### Requirement: Render-time JetStream budget check
The Helm chart SHALL fail to render when the worst-case per-server reservation exceeds 85% of `max_file_store`, unless `nats.jetstream.allowOvercommit` is true.
The worst case SHALL be computed as the sum of reservations replicated to every server, plus the single-replica total divided by `nats.replicas`, plus the largest single-replica reservation. The failure message SHALL list every reservation and the computed limit.

#### Scenario: Chart defaults with flow-collector enabled
- **GIVEN** chart defaults with `flowCollector.enabled: true`
- **WHEN** `helm template` renders the chart
- **THEN** rendering SHALL succeed

#### Scenario: Overrides exceed the budget
- **GIVEN** `datasvc.objectStoreBytes` is raised so the worst case exceeds 85% of `max_file_store`
- **WHEN** `helm upgrade` renders the chart
- **THEN** rendering SHALL fail
- **AND** the message SHALL list each stream's reservation and the limit

#### Scenario: Operator accepts overcommit
- **GIVEN** the same overrides and `nats.jetstream.allowOvercommit: true`
- **WHEN** `helm upgrade` renders the chart
- **THEN** rendering SHALL succeed

### Requirement: Stream owners never shrink below stored bytes
A component that reconciles `max_bytes` on an existing stream or bucket SHALL NOT set it below the bytes the stream currently stores.
When the configured value is lower than the stored bytes, the component SHALL keep the larger value and log both values.

#### Scenario: Lowered default with data that fits
- **GIVEN** `OBJ_serviceradar-objects` stores 0.5 GiB with `max_bytes` 10 GiB
- **AND** the configured `objectStoreBytes` is 4 GiB
- **WHEN** datasvc starts
- **THEN** the bucket's `max_bytes` SHALL become 4 GiB

#### Scenario: Lowered default with data that does not fit
- **GIVEN** `OBJ_serviceradar-objects` stores 6 GiB with `max_bytes` 10 GiB
- **AND** the configured `objectStoreBytes` is 4 GiB
- **WHEN** datasvc starts
- **THEN** the bucket SHALL keep a `max_bytes` of at least 6 GiB
- **AND** no stored object SHALL be removed

### Requirement: EventWriter can be disabled through Helm
The Helm chart SHALL render `EVENT_WRITER_ENABLED` as `"false"` when `core.eventWriter.enabled` is `false`.

#### Scenario: Disabled EventWriter
- **GIVEN** `core.eventWriter.enabled: false`
- **WHEN** the chart renders the core Deployment
- **THEN** `EVENT_WRITER_ENABLED` SHALL be `"false"`
