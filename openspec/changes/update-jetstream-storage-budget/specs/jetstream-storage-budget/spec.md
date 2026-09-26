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
- **GIVEN** `nats.jetstream.maxFileStore` is `30Gi` and `nats.persistence.size` is `40Gi`
- **WHEN** the chart renders the NATS configuration
- **THEN** `max_file_store` SHALL be `32212254720`

#### Scenario: Persistence size does not change the cap
- **GIVEN** `nats.persistence.size` is raised and neither `maxFileStore` nor the profile changes
- **WHEN** the chart renders the NATS configuration
- **THEN** `max_file_store` SHALL be unchanged

### Requirement: Render-time JetStream budget check
The Helm chart SHALL fail to render when the worst-case per-server reservation exceeds 85% of `max_file_store`, unless `nats.jetstream.allowOvercommit` is true.
Each stream's size and replica count SHALL come from its own chart value: `datasvc.jetstreamReplicas`, `logCollector.streamMaxBytes` and `logCollector.streamReplicas`, `flowCollector.config.stream_max_bytes` and `stream_replicas`, `bmpCollector.config.streamMaxBytes` and `streamReplicas`, `webNg.pluginStorage.jetstreamMaxBucketBytes` and `jetstreamReplicas`, `webNg.fieldSurveyArtifactStore.jetstreamMaxBucketBytes`, the core threat-intel bucket value, and `core.eventWriter.streams.<name>.maxBytes` with 1 replica for every EventWriter-created stream, including `trivy_reports`. `flows` and `ARANCINI_CAUSAL` SHALL be counted at the collector's size and replicas whether or not the collector is enabled, because a collector that claimed a stream keeps its size after it is disabled; the EventWriter fallbacks SHALL NOT be counted. A size SHALL be set through the environment of the component that creates the bucket.
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
The Helm chart SHALL fail to render when `max_file_store` exceeds 94% of the byte size of `nats.persistence.size`, and the message SHALL point at the volume-expansion runbook. `nats.jetstream.allowOvercommit` SHALL NOT skip this check.

#### Scenario: Larger profile on an unexpanded PVC
- **GIVEN** an existing install with `nats.persistence.size` of `30Gi`
- **AND** `nats.jetstream.profile` is `medium`
- **WHEN** `helm upgrade` renders the chart
- **THEN** rendering SHALL fail with a message that points at the volume-expansion runbook

#### Scenario: Larger profile through the volume-expansion runbook
- **GIVEN** a live `small` install on a StorageClass with `allowVolumeExpansion`
- **WHEN** the operator patches each `serviceradar-nats` PVC to `100Gi`, waits for the resize, deletes the StatefulSet with `--cascade=orphan`, and runs `helm upgrade` with `nats.persistence.size` of `100Gi` and `nats.jetstream.profile` of `medium`
- **THEN** rendering SHALL succeed
- **AND** the StatefulSet SHALL be recreated with the new `volumeClaimTemplates`
- **AND** the PVCs SHALL be the same objects, now `100Gi`
- **AND** every NATS pod SHALL become ready after a one-at-a-time roll

#### Scenario: Storage without expansion
- **GIVEN** a StorageClass without `allowVolumeExpansion`
- **WHEN** the operator wants a larger profile
- **THEN** the runbook SHALL state that the install needs a new install or a data migration
- **AND** the chart SHALL NOT attempt to automate it

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
- **THEN** the `small` profile SHALL apply, including 8 GiB for `flows` and 2 GiB for `ARANCINI_CAUSAL` as the collector sizes

#### Scenario: Explicit size overrides the profile
- **GIVEN** `nats.jetstream.profile` is `small` and `datasvc.objectStoreBytes` is set to 2 GiB
- **WHEN** the chart renders
- **THEN** the object store SHALL be 2 GiB and every other size SHALL keep its `small` value

#### Scenario: Every profile passes with all producers enabled
- **GIVEN** each profile on a matching `nats.persistence.size` with flow-collector, bmp-collector and the trivy sidecar enabled
- **WHEN** the chart renders
- **THEN** rendering SHALL succeed

### Requirement: Stream owners reconcile max_bytes by discard policy
The web-ng plugin bucket owner, the web-ng fieldsurvey bucket owner and the core threat-intel bucket owner SHALL reconcile `max_bytes` on startup, creating the bucket when it is absent and updating it when it exists.
The bmp-collector publisher SHALL create-or-update `ARANCINI_CAUSAL`, and the flow-collector publisher SHALL reconcile `flows`, each reconciling `max_bytes` and `num_replicas` on an existing stream.
For a discard-new state bucket (datasvc KV, `OBJ_serviceradar-objects`, and the plugin, fieldsurvey and threat-intel buckets), when the configured `max_bytes` is below the bytes currently stored, the owner SHALL leave `max_bytes` unchanged, SHALL NOT set it to the stored size, and SHALL log the configured, stored and current values. An existing unlimited bucket whose stored bytes exceed the configured cap SHALL stay unlimited, and be logged, until the data ages out or an operator raises the cap.
For a discard-old buffer stream (`flows`, `events`, `ARANCINI_CAUSAL` and every EventWriter-created stream), the owner SHALL reconcile `max_bytes` to the configured value even when that evicts the oldest messages, and SHALL log the values before and after.

#### Scenario: Lowered default with data that fits
- **GIVEN** `OBJ_serviceradar-objects` stores 0.5 GiB with `max_bytes` 10 GiB
- **AND** the configured `objectStoreBytes` is 4 GiB
- **WHEN** datasvc starts
- **THEN** the bucket's `max_bytes` SHALL become 4 GiB

#### Scenario: Existing unlimited bucket gains a cap
- **GIVEN** the `serviceradar_fieldsurvey` object store exists with no `max_bytes` and stores 0.1 GiB
- **AND** the configured fieldsurvey size is 1 GiB
- **WHEN** web-ng starts
- **THEN** the bucket's `max_bytes` SHALL become 1 GiB
- **AND** no stored object SHALL be removed

#### Scenario: Absent bucket is created with the cap
- **GIVEN** the plugin bucket does not exist and the configured plugin size is 2 GiB
- **WHEN** web-ng starts
- **THEN** the bucket SHALL be created with a `max_bytes` of 2 GiB

#### Scenario: State bucket holding more than the cap is unchanged
- **GIVEN** `OBJ_serviceradar-objects` stores 6 GiB with `max_bytes` 10 GiB
- **AND** the configured `objectStoreBytes` is 4 GiB
- **WHEN** datasvc starts
- **THEN** the bucket's `max_bytes` SHALL remain 10 GiB
- **AND** the log SHALL record the configured 4 GiB, the stored 6 GiB and the current 10 GiB
- **AND** no stored object SHALL be removed and later uploads SHALL still succeed

#### Scenario: Unlimited state bucket holding more than the cap
- **GIVEN** the `serviceradar_fieldsurvey` object store has no `max_bytes` and stores 3 GiB
- **AND** the configured fieldsurvey size is 1 GiB
- **WHEN** web-ng starts
- **THEN** the bucket SHALL stay unlimited
- **AND** the log SHALL record the configured, stored and current values
- **AND** later uploads SHALL still succeed

#### Scenario: Full buffer stream shrinks and evicts
- **GIVEN** `flows` holds 10 GiB with `max_bytes` 10 GiB
- **AND** the profile's `flows` size is 8 GiB
- **WHEN** flow-collector starts
- **THEN** the stream's `max_bytes` SHALL become 8 GiB
- **AND** the oldest messages SHALL be evicted to fit
- **AND** the log SHALL record the before and after values

#### Scenario: bmp-collector reconciles an existing stream
- **GIVEN** `ARANCINI_CAUSAL` exists with 10 GiB `max_bytes` and stores 0.5 GiB
- **AND** `bmpCollector.config.streamMaxBytes` is 2 GiB
- **WHEN** bmp-collector starts
- **THEN** the stream's `max_bytes` SHALL become 2 GiB

### Requirement: One owner reconciles each stream shape
Exactly one component SHALL reconcile the shape (`max_bytes`, replicas, retention) of a given stream. For `events`, `flows` and `ARANCINI_CAUSAL`, which the otel log-collector, flow-collector or bmp-collector and EventWriter can each write, the owner SHALL be recorded in the stream's metadata under the key `serviceradar.owner`, with the values `otel-log-collector`, `flow-collector`, `bmp-collector` and `event-writer`.
When its dedicated component runs it SHALL set `serviceradar.owner` to its own name on its stream, creating the stream when absent, and reconcile the shape; that claim SHALL override an `event-writer` claim.
EventWriter SHALL claim only streams it creates. It SHALL create `events`, `flows` and `ARANCINI_CAUSAL` when absent with `serviceradar.owner` set to `event-writer` and the fallback size and replicas from `SERVICERADAR_JS_<STREAM>_FALLBACK_MAX_BYTES` and `_FALLBACK_REPLICAS`, never unlimited, and it SHALL reconcile a stream it claimed. It SHALL merge subjects only, never overriding the claim, when another component holds it.
A stream created before this change has no metadata. EventWriter SHALL merge subjects only on such a stream and SHALL NOT change its shape until the stream has stayed unclaimed for a grace period of 15 minutes by default; only then SHALL it set `serviceradar.owner` to `event-writer` and reconcile the shape.
EventWriter SHALL check this with an ownership reconcile timer, a periodic tick in its producer, every 5 minutes by default and configurable, that re-reads each multi-owner stream it consumes, records in process state when it first saw the stream unclaimed, and applies the claim rule. The timer SHALL only issue stream updates and SHALL NOT tear down or resubscribe a consumer, and it SHALL be distinct from the retry of consumers that failed to set up. A restart SHALL reset the recorded time, which can delay convergence but SHALL NOT cause an early claim. A dedicated component SHALL claim a legacy stream as soon as it starts, without waiting. EventWriter SHALL re-read the stream immediately before its claim update and skip the update if any claim has appeared.
When a collector is disabled after claiming a stream, the claim and the stream size SHALL remain until an operator reclaims it, and the runbook SHALL document the reclaim. The render-time budget and the non-Helm preset budget SHALL count `flows` and `ARANCINI_CAUSAL` at the collector size whether or not the collector is enabled.
An ownership test SHALL exercise the EventWriter claim decision, with an injected clock, for each of `events`, `flows` and `ARANCINI_CAUSAL` with no claim inside and after the grace period, an `event-writer` claim and a collector claim, including a restart that resets the clock, and SHALL fail if EventWriter reconciles the shape of a stream claimed by another component or of a legacy stream inside the grace period. Behaviour of the Go and Rust owners is covered by each owner's own tests.

#### Scenario: Claim on first start
- **GIVEN** `ARANCINI_CAUSAL` does not exist and bmp-collector is enabled
- **WHEN** bmp-collector starts
- **THEN** it SHALL create the stream with `serviceradar.owner` set to `bmp-collector` and its configured size and replicas

#### Scenario: Collector claim overrides an EventWriter claim
- **GIVEN** `flows` exists with `serviceradar.owner` set to `event-writer` and a 1 GiB `max_bytes`
- **WHEN** flow-collector starts
- **THEN** it SHALL set `serviceradar.owner` to `flow-collector`
- **AND** the stream's `max_bytes` and replicas SHALL become its configured values

#### Scenario: EventWriter does not reconcile a collector-claimed stream
- **GIVEN** `events` exists with `serviceradar.owner` set to `otel-log-collector` and a 2 GiB `max_bytes`
- **WHEN** EventWriter starts
- **THEN** the stream's `max_bytes`, replicas and retention SHALL be unchanged
- **AND** EventWriter SHALL only merge its subjects

#### Scenario: Upgrade with a collector, legacy stream, no eviction
- **GIVEN** an install with flow-collector enabled and `flows` with no metadata and a 10 GiB `max_bytes` holding 9 GiB, created earlier by EventWriter
- **WHEN** core and flow-collector restart together and EventWriter's consumers set up first
- **THEN** EventWriter SHALL merge subjects only and SHALL NOT change `max_bytes`, replicas or retention
- **AND** flow-collector SHALL claim the stream and set `max_bytes` to 8 GiB with its configured replicas
- **AND** no message SHALL be evicted by EventWriter

#### Scenario: Upgrade with no collector, legacy stream converges after the grace period
- **GIVEN** an install with no collector and `flows` with no metadata and a 10 GiB `max_bytes`, created earlier by EventWriter
- **WHEN** EventWriter sets up its consumers
- **THEN** it SHALL leave the shape unchanged during the 15 minute grace period
- **AND** after the stream has stayed unclaimed for the grace period it SHALL set `serviceradar.owner` to `event-writer` and reconcile `max_bytes` to the 1 GiB fallback, evicting the oldest messages and logging the values before and after

#### Scenario: The timer converges a stream that set up successfully
- **GIVEN** a collector-less install whose `flows` consumers set up successfully on a legacy 10 GiB stream, merging subjects only
- **WHEN** the ownership reconcile timer ticks after the stream has been observed unclaimed for the grace period
- **THEN** it SHALL claim the stream for `event-writer` and reconcile it to the fallback
- **AND** no consumer SHALL be torn down or resubscribed

#### Scenario: Restart resets the grace clock
- **GIVEN** EventWriter observed a legacy stream unclaimed for 10 minutes and then restarts
- **WHEN** the timer ticks after the restart
- **THEN** the grace period SHALL start again and the stream SHALL NOT be claimed until it has been unclaimed for the full grace period after the restart

#### Scenario: A collector claims inside the grace period
- **GIVEN** a legacy `flows` stream and EventWriter within its grace period
- **WHEN** flow-collector starts and claims the stream before the grace period ends
- **THEN** EventWriter SHALL find the collector claim and SHALL NOT claim or reconcile the stream

#### Scenario: EventWriter re-reads before claiming
- **GIVEN** a legacy stream that has stayed unclaimed for the grace period
- **AND** a collector claims it between EventWriter's check and its update
- **WHEN** EventWriter re-reads the stream immediately before updating
- **THEN** it SHALL skip the update

#### Scenario: EventWriter creates the stream when it is absent
- **GIVEN** `ARANCINI_CAUSAL` does not exist and no bmp-collector is running
- **WHEN** EventWriter starts
- **THEN** it SHALL create the stream with `serviceradar.owner` set to `event-writer` and the 1 GiB fallback `max_bytes`, not unlimited, and claim needs no grace period because EventWriter created it

#### Scenario: Collector disabled after claiming
- **GIVEN** `ARANCINI_CAUSAL` is claimed by `bmp-collector` at 12 GiB and bmp-collector is then disabled
- **WHEN** EventWriter starts
- **THEN** the stream SHALL remain at 12 GiB
- **AND** the budget SHALL already have counted it at the collector size
- **AND** the runbook reclaim SHALL make EventWriter reconcile it to the fallback

#### Scenario: EventWriter claim decision is safe
- **GIVEN** each of `events`, `flows` and `ARANCINI_CAUSAL` with no claim, an `event-writer` claim and a collector claim
- **WHEN** the ownership test runs
- **THEN** EventWriter SHALL reconcile only the unclaimed and `event-writer` cases

### Requirement: Size-owning services honour environment size overrides
The Go datasvc, the otel log-collector, the flow-collector and the bmp-collector SHALL read their stream sizes and replica counts from `SERVICERADAR_JS_<STREAM>_MAX_BYTES` and `SERVICERADAR_JS_<STREAM>_REPLICAS`, where `<STREAM>` is the stream name upper-cased with each non-alphanumeric character replaced by `_`.
The precedence SHALL be environment, then the JSON or TOML value, then the compiled default. A value that is not a positive integer SHALL fail startup.

#### Scenario: Environment overrides the file
- **GIVEN** the flow-collector JSON sets `stream_max_bytes` to 1 GiB
- **AND** `SERVICERADAR_JS_FLOWS_MAX_BYTES` is 3 GiB
- **WHEN** flow-collector resolves its configuration
- **THEN** the `flows` stream size SHALL be 3 GiB

#### Scenario: File overrides the compiled default
- **GIVEN** no size environment variable is set and the JSON sets a size
- **WHEN** the component resolves its configuration
- **THEN** the JSON value SHALL be used

#### Scenario: Invalid value
- **GIVEN** `SERVICERADAR_JS_ARANCINI_CAUSAL_MAX_BYTES` is `abc`
- **WHEN** bmp-collector starts
- **THEN** startup SHALL fail with an error naming the variable

### Requirement: Non-Helm installs ship explicit profile sizes that fit
Docker Compose SHALL ship one preset file per sizing profile that sets `max_file_store` and every stream size explicitly, and packaged installs SHALL ship the same explicit sizes as a file; the NATS server configuration SHALL read `max_file_store` from them.
For every preset the worst-case reservation, computed as for the Helm chart with `nats.replicas` equal to 1, SHALL NOT exceed 85% of `max_file_store`.
A Bazel test SHALL enforce this by parsing the NATS server configuration with the NATS configuration parser and the preset and sizes files into typed values, without reading component source. The test SHALL fail on a missing or unknown stream key, including the EventWriter fallback keys for `events`, `flows` and `ARANCINI_CAUSAL`, or a non-positive size.
The test SHALL also parse `docker-compose.yml` and the packaged systemd units into typed models and SHALL fail when a size-owning service does not load the selected preset (`env_file`) or the sizes file (`EnvironmentFile`).

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

#### Scenario: A service does not load the preset
- **GIVEN** a size-owning Compose service, or a packaged unit, that does not load the selected preset or sizes file
- **WHEN** the budget test runs
- **THEN** the test SHALL fail and name the service

#### Scenario: A preset overcommits
- **GIVEN** a shipped stream size is raised so the sum exceeds 85% of `max_file_store`
- **WHEN** the budget test runs
- **THEN** the test SHALL fail and name the streams and the limit
