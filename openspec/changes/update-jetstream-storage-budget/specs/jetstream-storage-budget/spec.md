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
The chart SHALL take the value from `nats.jetstream.maxFileStore` when set and otherwise from the selected sizing profile, and SHALL NOT derive it from `nats.persistence.size`. `G` SHALL mean 10^9 bytes and `Gi` SHALL mean 2^30 bytes, matching NATS.

#### Scenario: Chart default
- **GIVEN** no `nats.jetstream.maxFileStore` and the default `small` profile
- **WHEN** the chart renders the NATS configuration
- **THEN** `max_file_store` SHALL be `30000000000`

#### Scenario: Binary suffix override
- **GIVEN** `nats.jetstream.maxFileStore` is `30Gi`
- **WHEN** the chart renders the NATS configuration
- **THEN** `max_file_store` SHALL be `32212254720`

#### Scenario: Persistence size does not change the cap
- **GIVEN** `nats.persistence.size` is raised and neither `maxFileStore` nor the profile changes
- **WHEN** the chart renders the NATS configuration
- **THEN** `max_file_store` SHALL be unchanged

### Requirement: Render-time JetStream budget check
The Helm chart SHALL fail to render when the worst-case per-server reservation exceeds 85% of `max_file_store`, unless `nats.jetstream.allowOvercommit` is true.
Each stream's size and replica count SHALL come from its own chart value: `datasvc.jetstreamReplicas`, `logCollector.streamReplicas`, `flowCollector.config.stream_max_bytes` and `stream_replicas` when flow-collector is enabled, `bmpCollector.config.streamMaxBytes` and `streamReplicas` when bmp-collector is enabled, `webNg.pluginStorage.jetstreamReplicas`, and 1 replica for every EventWriter-created stream, including `trivy_reports` and the `flows` and `ARANCINI_CAUSAL` fallbacks while their collector is disabled.
A stream whose replicas are greater than or equal to `nats.replicas` SHALL count its full `max_bytes` on every server. The worst case SHALL be computed as the sum of those reservations, plus the sum over every other stream of `max_bytes` times replicas divided by `nats.replicas`, plus the largest `max_bytes` among the other streams. The failure message SHALL list every reservation with its replicas and the computed limit.

#### Scenario: Chart defaults with every optional producer enabled
- **GIVEN** chart defaults with `flowCollector.enabled: true`, `bmpCollector.enabled: true` and the trivy sidecar enabled
- **WHEN** `helm template` renders the chart
- **THEN** rendering SHALL succeed

#### Scenario: BMP stream is counted
- **GIVEN** `bmpCollector.enabled: true` and `bmpCollector.config.streamMaxBytes` is raised so the worst case exceeds 85% of `max_file_store`
- **WHEN** `helm template` renders the chart
- **THEN** rendering SHALL fail and the message SHALL list `ARANCINI_CAUSAL` with its size and replicas

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

### Requirement: NATS file store fits the disk
The Helm chart SHALL fail to render when `max_file_store` exceeds 94% of the byte size of `nats.persistence.size`, and the message SHALL tell the operator to expand the PVC out of band and raise `nats.persistence.size` first. `nats.jetstream.allowOvercommit` SHALL NOT skip this check.

#### Scenario: Larger profile on an unexpanded PVC
- **GIVEN** an existing install with `nats.persistence.size` of `30Gi`
- **AND** `nats.jetstream.profile` is `medium`
- **WHEN** `helm upgrade` renders the chart
- **THEN** rendering SHALL fail with a message to expand the PVC and raise `nats.persistence.size`

#### Scenario: Larger profile after expansion
- **GIVEN** the PVC has been expanded out of band and `nats.persistence.size` is `100Gi`
- **AND** `nats.jetstream.profile` is `medium`
- **WHEN** `helm upgrade` renders the chart
- **THEN** rendering SHALL succeed

#### Scenario: Shipped profiles fit their PVC
- **GIVEN** `small` on `30Gi`, `medium` on `100Gi` and `large` on `500Gi`
- **WHEN** the chart renders each
- **THEN** each SHALL pass this check

#### Scenario: Overcommit does not bypass the disk check
- **GIVEN** `nats.jetstream.allowOvercommit: true` and `max_file_store` above 94% of `nats.persistence.size`
- **WHEN** the chart renders
- **THEN** rendering SHALL fail

### Requirement: JetStream sizing profiles
The Helm chart SHALL provide sizing profiles `small`, `medium` and `large`, selected by `nats.jetstream.profile` with `small` as the default, and Docker Compose SHALL select the same profiles with `SERVICERADAR_NATS_PROFILE`.
A profile SHALL set `max_file_store` (30G, 100G and 500G) and the default `max_bytes` of every stream, KV bucket and object store that ServiceRadar creates, including `flows` and `ARANCINI_CAUSAL`. An explicit value for a single size or for `maxFileStore` SHALL override the profile value. Every profile SHALL pass the render-time budget check with flow-collector, bmp-collector and the trivy sidecar all enabled, and with all of them disabled.

#### Scenario: Default profile
- **GIVEN** no profile is set
- **WHEN** the chart renders
- **THEN** the `small` profile SHALL apply, including 8 GiB for `flows` when flow-collector is enabled and 2 GiB for `ARANCINI_CAUSAL` when bmp-collector is enabled

#### Scenario: Explicit size overrides the profile
- **GIVEN** `nats.jetstream.profile` is `small` and `datasvc.objectStoreBytes` is set to 2 GiB
- **WHEN** the chart renders
- **THEN** the object store SHALL be 2 GiB and every other size SHALL keep its `small` value

#### Scenario: Every profile passes with all producers enabled
- **GIVEN** each profile on a matching `nats.persistence.size` with flow-collector, bmp-collector and the trivy sidecar enabled
- **WHEN** the chart renders
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

### Requirement: Non-Helm installs ship explicit profile sizes that fit
Docker Compose SHALL ship one preset file per sizing profile that sets `max_file_store` and every stream size explicitly, and packaged installs SHALL ship the same explicit sizes as a file; the NATS server configuration SHALL read `max_file_store` from them.
For every preset the worst-case reservation, computed as for the Helm chart with `nats.replicas` equal to 1, SHALL NOT exceed 85% of `max_file_store`.
A Bazel test SHALL enforce this by parsing the NATS server configuration with the NATS configuration parser and the preset and sizes files into typed values, without reading component source. The test SHALL fail on a missing or unknown stream key or a non-positive size.

#### Scenario: Shipped Compose presets
- **GIVEN** the `small`, `medium` and `large` Compose presets and `docker/compose/nats.docker.conf`
- **WHEN** the budget test runs
- **THEN** each preset SHALL define every stream size explicitly
- **AND** the sum of every stream's `max_bytes` SHALL NOT exceed 85% of the parsed `max_file_store`

#### Scenario: Shipped packaged sizes
- **GIVEN** the packaged sizes file and `build/packaging/nats/config/nats-server.conf`
- **WHEN** the budget test runs
- **THEN** the same conditions SHALL hold

#### Scenario: A size is missing
- **GIVEN** a preset omits the size of one stream
- **WHEN** the budget test runs
- **THEN** the test SHALL fail and name the stream

#### Scenario: A preset overcommits
- **GIVEN** a shipped stream size is raised so the sum exceeds 85% of `max_file_store`
- **WHEN** the budget test runs
- **THEN** the test SHALL fail and name the streams and the limit

### Requirement: EventWriter can be disabled through Helm
The Helm chart SHALL render `EVENT_WRITER_ENABLED` as `"false"` when `core.eventWriter.enabled` is `false`.

#### Scenario: Disabled EventWriter
- **GIVEN** `core.eventWriter.enabled: false`
- **WHEN** the chart renders the core Deployment
- **THEN** `EVENT_WRITER_ENABLED` SHALL be `"false"`
