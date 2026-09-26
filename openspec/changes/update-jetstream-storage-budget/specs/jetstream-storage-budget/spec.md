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
The chart SHALL take the value from `nats.jetstream.maxFileStore` and SHALL NOT derive it from `nats.persistence.size`. `G` SHALL mean 10^9 bytes and `Gi` SHALL mean 2^30 bytes, matching NATS.

#### Scenario: Chart default
- **GIVEN** `nats.jetstream.maxFileStore` keeps its chart default of `30G`
- **WHEN** the chart renders the NATS configuration
- **THEN** `max_file_store` SHALL be `30000000000`

#### Scenario: Binary suffix override
- **GIVEN** `nats.jetstream.maxFileStore` is `30Gi`
- **WHEN** the chart renders the NATS configuration
- **THEN** `max_file_store` SHALL be `32212254720`

#### Scenario: Persistence size does not change the cap
- **GIVEN** `nats.persistence.size` is raised and `maxFileStore` is unchanged
- **WHEN** the chart renders the NATS configuration
- **THEN** `max_file_store` SHALL be unchanged

### Requirement: Render-time JetStream budget check
The Helm chart SHALL fail to render when the worst-case per-server reservation exceeds 85% of `max_file_store`, unless `nats.jetstream.allowOvercommit` is true.
Each stream's replica count SHALL come from its own chart value: `datasvc.jetstreamReplicas`, `logCollector.streamReplicas`, `flowCollector.config.stream_replicas` when flow-collector is enabled, `webNg.pluginStorage.jetstreamReplicas`, and 1 for EventWriter streams.
A stream whose replicas are greater than or equal to `nats.replicas` SHALL count its full `max_bytes` on every server. The worst case SHALL be computed as the sum of those reservations, plus the sum over every other stream of `max_bytes` times replicas divided by `nats.replicas`, plus the largest `max_bytes` among the other streams. The failure message SHALL list every reservation with its replicas and the computed limit.

#### Scenario: Chart defaults with flow-collector enabled
- **GIVEN** chart defaults with `flowCollector.enabled: true`
- **WHEN** `helm template` renders the chart
- **THEN** rendering SHALL succeed

#### Scenario: Intermediate replica count on a larger cluster
- **GIVEN** `nats.replicas` is 5 and a 10 GiB stream has 3 replicas
- **WHEN** the budget is computed
- **THEN** the stream SHALL contribute `10 * 3 / 5` GiB to the spread term and 10 GiB to the largest-stream term when it is the largest such stream
- **AND** it SHALL NOT be counted as replicated to every server

#### Scenario: The v1.4.73 shape
- **GIVEN** three servers, `max_file_store` 30G, and 26 GiB of streams replicated to every server plus 5.25 GiB of single-replica streams
- **WHEN** the budget is computed
- **THEN** the worst case SHALL be 28.75 GiB and rendering SHALL fail

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

### Requirement: Non-Helm installs ship a stream budget that fits
The Docker Compose and packaged install configurations SHALL ship stream sizes and a `max_file_store` for which the worst-case reservation, computed as for the Helm chart with `nats.replicas` equal to 1, does not exceed 85% of `max_file_store`.
A Bazel test SHALL enforce this by parsing the shipped NATS server configurations and the stream-size sources they rely on into typed values, using the compiled-in default for any size a config leaves unset, and evaluating the same formula. The test SHALL account for every optional collector those installs can enable.

#### Scenario: Shipped Compose configuration
- **GIVEN** `docker/compose/nats.docker.conf` and the Compose datasvc, otel, flow-collector, bmp-collector and core settings
- **WHEN** the budget test runs
- **THEN** the sum of every stream's `max_bytes` SHALL NOT exceed 85% of `max_file_store`

#### Scenario: Shipped packaged configuration
- **GIVEN** `build/packaging/nats/config/nats-server.conf` and the packaged datasvc, otel, flow-collector and core settings
- **WHEN** the budget test runs
- **THEN** the sum of every stream's `max_bytes` SHALL NOT exceed 85% of `max_file_store`

#### Scenario: A config change overcommits
- **GIVEN** a shipped stream size is raised so the sum exceeds 85% of `max_file_store`
- **WHEN** the budget test runs
- **THEN** the test SHALL fail and name the streams and the limit

### Requirement: EventWriter can be disabled through Helm
The Helm chart SHALL render `EVENT_WRITER_ENABLED` as `"false"` when `core.eventWriter.enabled` is `false`.

#### Scenario: Disabled EventWriter
- **GIVEN** `core.eventWriter.enabled: false`
- **WHEN** the chart renders the core Deployment
- **THEN** `EVENT_WRITER_ENABLED` SHALL be `"false"`
