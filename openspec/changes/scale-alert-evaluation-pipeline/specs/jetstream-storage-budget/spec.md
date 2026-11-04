## MODIFIED Requirements

### Requirement: JetStream sizing profiles
The Helm chart SHALL provide sizing profiles `tenant-2g`, `small`, `medium`, `large` and `xlarge`, selected by `nats.jetstream.profile` with `small` as the default, and Docker Compose SHALL select the same profiles with `SERVICERADAR_NATS_PROFILE`.
A profile SHALL set `max_file_store` (2G, 36G, 100G, 500G and 2000G) and the default `max_bytes` of every stream, KV bucket and object store that ServiceRadar creates through the chart, including `flows` and `ARANCINI_CAUSAL`. An explicit value for a single size or for `maxFileStore` SHALL override the profile value.
The signal-separated telemetry streams, the alert candidate streams and the telemetry and alert dead-letter streams SHALL take `max_bytes` from CNPG runtime settings whose code defaults are derived from the active profile; the chart SHALL supply only the NATS volume and `max_file_store` for them, and a size setting that would exceed the JetStream file store SHALL be rejected when it is saved. Each profile's candidate stream default SHALL hold 1 h of stored, S2-compressed bytes at that profile's planning candidate rate, using a stated conservative compression ratio that the fleet-scale gate measures, and these streams' defaults SHALL be carved from the profile's existing `events` and `metrics` allocations, which they replace, so that alert evaluation fits every profile. Every profile SHALL pass the render-time budget check with flow-collector, bmp-collector and the trivy sidecar all enabled, and with all of them disabled.

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

#### Scenario: The smallest profile still evaluates alerts
- **GIVEN** `nats.jetstream.profile` is `tenant-2g`
- **WHEN** the chart renders with every producer enabled
- **THEN** rendering SHALL succeed with the candidate stream and alert dead-letter defaults counted
- **AND** the candidate stream default SHALL hold one hour at the profile's planning candidate rate

#### Scenario: The xlarge profile holds the fleet-scale outage budget
- **GIVEN** `nats.jetstream.profile` is `xlarge` on a matching `nats.persistence.size`
- **WHEN** the chart renders
- **THEN** the code defaults derived for the alert candidate stream sizes SHALL hold one hour of stored, S2-compressed bytes at the documented sustained candidate rate and p99 candidate size per signal, at the stated conservative compression ratio
- **AND** rendering SHALL succeed with every producer enabled

### Requirement: Stream owners reconcile max_bytes by discard policy
The web-ng plugin bucket owner, the web-ng fieldsurvey bucket owner and the core threat-intel bucket owner SHALL reconcile `max_bytes` on startup, creating the bucket when it is absent and updating it when it exists.
The bmp-collector publisher SHALL create-or-update `ARANCINI_CAUSAL`, and the flow-collector publisher SHALL reconcile `flows`, each reconciling `max_bytes` and `num_replicas` on an existing stream.
For a discard-new state bucket (datasvc KV, `OBJ_serviceradar-objects`, and the plugin, fieldsurvey and threat-intel buckets), when the configured `max_bytes` is below the bytes currently stored, the owner SHALL leave `max_bytes` unchanged, SHALL NOT set it to the stored size, and SHALL log the configured, stored and current values. An existing unlimited bucket whose stored bytes exceed the configured cap SHALL stay unlimited, and be logged, until the data ages out or an operator raises the cap.
For a discard-old buffer stream (`flows`, `ARANCINI_CAUSAL` and every EventWriter-created stream whose records are neither stored nor alert-evaluated by EventWriter), the owner SHALL reconcile `max_bytes` to the configured value even when that evicts the oldest messages, and SHALL log the values before and after.
For a discard-new telemetry or evaluation stream (the signal-separated logs, events, OpenTelemetry and metrics streams, the alert candidate streams, and the telemetry and alert dead-letter streams), the owner SHALL treat `max_bytes` as for a discard-new state bucket: when the configured value is below the bytes currently stored it SHALL leave `max_bytes` unchanged and log the configured, stored and current values, and it SHALL NOT evict an accepted message to fit.

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

#### Scenario: A lowered candidate stream size does not evict
- **GIVEN** `ALERT_CANDIDATES_V1_S0` stores 12 GiB of unprocessed candidates with `max_bytes` 16 GiB
- **AND** the configured size is lowered to 8 GiB
- **WHEN** the coordinator reconciles the stream
- **THEN** its `max_bytes` SHALL remain 16 GiB
- **AND** no candidate SHALL be removed
- **AND** the log SHALL record the configured 8 GiB, the stored 12 GiB and the current 16 GiB

### Requirement: NATS file store is rendered as an exact byte count
The Helm chart SHALL render `max_file_store` as an integer number of bytes.
The chart SHALL take the value from `nats.jetstream.maxFileStore` when set and otherwise from the selected sizing profile, and SHALL NOT derive it from `nats.persistence.size`. `G` SHALL mean 10^9 bytes and `Gi` SHALL mean 2^30 bytes, matching NATS.

#### Scenario: Chart default
- **GIVEN** no `nats.jetstream.maxFileStore` and the default `small` profile
- **WHEN** the chart renders the NATS configuration
- **THEN** `max_file_store` SHALL be `36000000000`

#### Scenario: Binary suffix override
- **GIVEN** `nats.jetstream.maxFileStore` is `30Gi` and `nats.persistence.size` is `40Gi`
- **WHEN** the chart renders the NATS configuration
- **THEN** `max_file_store` SHALL be `32212254720`

#### Scenario: Persistence size does not change the cap
- **GIVEN** `nats.persistence.size` is raised and neither `maxFileStore` nor the profile changes
- **WHEN** the chart renders the NATS configuration
- **THEN** `max_file_store` SHALL be unchanged

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
- **GIVEN** `tenant-2g` on `3Gi`, `small` on `36Gi`, `medium` on `100Gi`, `large` on `500Gi` and `xlarge` on `2000Gi`
- **WHEN** the chart renders each
- **THEN** each SHALL pass this check

#### Scenario: Overcommit does not bypass the disk check
- **GIVEN** `nats.jetstream.allowOvercommit: true` and `max_file_store` above 94% of `nats.persistence.size`
- **WHEN** the chart renders
- **THEN** rendering SHALL fail

### Requirement: One owner reconciles each stream shape
Exactly one component SHALL reconcile the shape (`max_bytes`, replicas, retention) of a given stream. For `flows` and `ARANCINI_CAUSAL`, which flow-collector or bmp-collector and EventWriter can each write, the owner SHALL be recorded in the stream's metadata under the key `serviceradar.owner`, with the values `flow-collector`, `bmp-collector` and `event-writer`. The signal-separated telemetry streams SHALL have EventWriter as their only owner, created with their CNPG sizes, and no component SHALL create or update the retired `events` stream, which SHALL first be unbound from every subject a publisher uses and SHALL be deleted only after every message it stored up to that unbind, including those on the new block subjects, has been acknowledged; every component that creates or updates it today (EventWriter, Zen, the OTEL collector, flowgger and trapd) SHALL stop doing so before it is deleted.
When its dedicated component runs it SHALL set `serviceradar.owner` to its own name on its stream, creating the stream when absent, and reconcile the shape; that claim SHALL override an `event-writer` claim.
EventWriter SHALL claim only streams it creates. It SHALL create `flows` and `ARANCINI_CAUSAL` when absent with `serviceradar.owner` set to `event-writer` and the fallback size and replicas from `SERVICERADAR_JS_<STREAM>_FALLBACK_MAX_BYTES` and `_FALLBACK_REPLICAS`, never unlimited, and it SHALL reconcile a stream it claimed. It SHALL merge subjects only, never overriding the claim, when another component holds it.
A stream created before this change has no metadata. EventWriter SHALL merge subjects only on such a stream and SHALL NOT change its shape until the stream has stayed unclaimed for a grace period of 15 minutes by default; only then SHALL it set `serviceradar.owner` to `event-writer` and reconcile the shape.
EventWriter SHALL check this with an ownership reconcile timer, a periodic tick in the coordinator-only consumer reconciler (one per deployment), every 5 minutes by default and configurable, that re-reads each multi-owner stream it consumes, records in process state when it first saw the stream unclaimed, and applies the claim rule. The timer SHALL only issue stream updates and SHALL NOT tear down or resubscribe a consumer, and it SHALL be distinct from the retry of consumers that failed to set up. A restart SHALL reset the recorded time, which can delay convergence but SHALL NOT cause an early claim.
The timer SHALL watch every multi-owner stream the EventWriter consumes for the life of the process. On each tick it SHALL reconcile the shape of a stream claimed by `event-writer` if it drifted, merge subjects only on a stream claimed by a collector, and apply the grace period to an unclaimed stream, so a reclaim takes effect within one tick on a running install. A dedicated component SHALL claim a legacy stream as soon as it starts, without waiting. EventWriter SHALL re-read the stream immediately before its claim update and skip the update if any claim has appeared.
When a collector is disabled after claiming a stream, the claim and the stream size SHALL remain until an operator reclaims it, and the runbook SHALL document the reclaim. The render-time budget and the non-Helm preset budget SHALL count `flows` and `ARANCINI_CAUSAL` at the collector size whether or not the collector is enabled.
An ownership test SHALL exercise the EventWriter claim decision, with an injected clock, for each of `flows` and `ARANCINI_CAUSAL` with no claim inside and after the grace period, an `event-writer` claim and a collector claim, including a restart that resets the clock, and SHALL fail if EventWriter reconciles the shape of a stream claimed by another component or of a legacy stream inside the grace period. Behaviour of the Go and Rust owners is covered by each owner's own tests.

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
- **GIVEN** `flows` exists with `serviceradar.owner` set to `flow-collector` and an 8 GiB `max_bytes`
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
- **WHEN** EventWriter starts and its ownership timer ticks
- **THEN** the stream SHALL remain at 12 GiB
- **AND** the budget SHALL already have counted it at the collector size

#### Scenario: Reclaim by setting the owner
- **GIVEN** `ARANCINI_CAUSAL` is claimed by `bmp-collector` at 12 GiB, bmp-collector is disabled, and EventWriter is running
- **WHEN** an operator sets `serviceradar.owner` to `event-writer` with the runbook command
- **THEN** at the next ownership timer tick, with no grace period and no core restart, EventWriter SHALL reconcile the stream to the fallback

#### Scenario: Reclaim by removing the claim
- **GIVEN** the same stream and an operator who removes `serviceradar.owner`
- **WHEN** the ownership timer ticks
- **THEN** EventWriter SHALL treat the stream as unclaimed and start the grace period, and SHALL claim and reconcile it only after the grace period

#### Scenario: EventWriter claim decision is safe
- **GIVEN** each of `flows` and `ARANCINI_CAUSAL` with no claim, an `event-writer` claim and a collector claim
- **WHEN** the ownership test runs
- **THEN** EventWriter SHALL reconcile only the unclaimed and `event-writer` cases

## ADDED Requirements

### Requirement: Alert candidate streams are inside the JetStream budget
The render-time budget check SHALL include every alert candidate stream and the alert dead-letter stream at their profile-derived default size and replica count.
When a candidate stream cannot be created or placed, EventWriter SHALL keep every other consumer subscribed, SHALL retry only that stream's setup with backoff, and SHALL hold unacknowledged only the source messages whose candidates target its blocks.

#### Scenario: A candidate stream cannot be placed
- **GIVEN** NATS rejects creating `ALERT_CANDIDATES_V1_S2` for insufficient storage
- **WHEN** EventWriter starts
- **THEN** the logs, events, OpenTelemetry and metrics consumers SHALL stay subscribed
- **AND** a source message whose candidates target blocks of `ALERT_CANDIDATES_V1_S2` SHALL stay unacknowledged and SHALL be routed once that stream is placed
- **AND** only the setup of `ALERT_CANDIDATES_V1_S2` SHALL be retried
- **AND** a health event SHALL name `ALERT_CANDIDATES_V1_S2` and the NATS error
