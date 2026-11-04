## MODIFIED Requirements

### Requirement: JetStream sizing profiles
The Helm chart SHALL provide sizing profiles `small`, `medium`, `large` and `xlarge`, selected by `nats.jetstream.profile` with `small` as the default, and Docker Compose SHALL select the same profiles with `SERVICERADAR_NATS_PROFILE`.
A profile SHALL set `max_file_store` (30G, 100G, 500G and 2000G) and the default `max_bytes` of every stream, KV bucket and object store that ServiceRadar creates, including `flows`, `ARANCINI_CAUSAL`, the signal-separated telemetry streams and the alert candidate and dead-letter streams. An explicit value for a single size or for `maxFileStore` SHALL override the profile value. Every profile SHALL pass the render-time budget check with flow-collector, bmp-collector and the trivy sidecar all enabled, and with all of them disabled.

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

#### Scenario: The xlarge profile holds the fleet-scale outage budget
- **GIVEN** `nats.jetstream.profile` is `xlarge` on a matching `nats.persistence.size`
- **WHEN** the chart renders
- **THEN** the alert candidate streams SHALL be sized for one hour at the documented sustained candidate rate
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

## ADDED Requirements

### Requirement: Alert candidate streams are inside the JetStream budget
The render-time budget check SHALL include every alert candidate stream and the alert dead-letter stream at their configured size and replica count.
When a candidate stream cannot be created or placed, EventWriter SHALL keep every other consumer subscribed, SHALL retry only that stream's setup with backoff, and SHALL hold unacknowledged only the source messages whose candidates target its blocks.

#### Scenario: A candidate stream cannot be placed
- **GIVEN** NATS rejects creating `ALERT_CANDIDATES_V1_S2` for insufficient storage
- **WHEN** EventWriter starts
- **THEN** the logs, events and metrics consumers SHALL stay subscribed and store records that produce no candidate for those blocks
- **AND** only the setup of `ALERT_CANDIDATES_V1_S2` SHALL be retried
- **AND** a health event SHALL name `ALERT_CANDIDATES_V1_S2` and the NATS error
