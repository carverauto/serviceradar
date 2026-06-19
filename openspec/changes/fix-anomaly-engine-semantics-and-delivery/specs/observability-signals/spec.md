## ADDED Requirements
### Requirement: Anomaly Finding Timestamp Fidelity
The causal signal ingestion path SHALL preserve anomaly and capacity finding event
time from the producer payload, including numeric OCSF timestamps, rather than
falling back to ingest time when the timestamp is not ISO8601.

#### Scenario: Edge anomaly uses numeric OCSF time
- **GIVEN** an edge anomaly add-on emits an OCSF Detection Finding with numeric `time`
- **WHEN** core-elx routes the finding through the causal prediction spine
- **THEN** EventWriter SHALL persist the finding with that event time
- **AND** it SHALL NOT replace the event time with `DateTime.utc_now()` solely because the payload timestamp is numeric

#### Scenario: Causal finding accepts common Unix units
- **WHEN** a causal anomaly or capacity finding carries a Unix timestamp in seconds, milliseconds, microseconds, or nanoseconds
- **THEN** core-elx SHALL normalize it to the correct `DateTime`
- **AND** malformed or missing timestamps SHALL fall back to ingest time with bounded diagnostics

### Requirement: Canonical Anomaly Finding Identity
Core-elx SHALL derive persisted anomaly finding identity from canonical device and
series fields after re-keying, not from provisional producer hints.

#### Scenario: Edge verdict is re-keyed
- **GIVEN** an edge anomaly verdict carries a provisional `anomaly.series_key`
- **AND** `source_identity` can be resolved to a different canonical series key
- **WHEN** core-elx republishes and persists the verdict
- **THEN** `anomaly.series_key`, `source_identity.series_key`, `metadata.service_radar.series_key`, and `metadata.finding_info.uid` SHALL be derived from the canonical series
- **AND** the finding identity dimensions SHALL use the same canonical device uid and metric class as the persisted row

### Requirement: Seasonal Anomaly Confirmation Persistence
Central seasonal anomaly confirmation SHALL persist across scheduled worker runs
and core-elx restarts.

#### Scenario: Sustained seasonal breach spans runs
- **GIVEN** central seasonal anomaly detection requires more than one confirm slot
- **WHEN** consecutive worker runs evaluate the same `(source, series_key, dow, hod)` as breaching
- **THEN** core-elx SHALL carry the confirmation counter across those runs
- **AND** it SHALL emit the central seasonal anomaly finding once the configured confirmation count is reached

#### Scenario: Seasonal state is bounded
- **WHEN** a seasonal anomaly state key has not been refreshed within the configured retention window
- **THEN** core-elx SHALL remove or ignore that stale state
- **AND** stale state SHALL NOT grow without bound as series churn

### Requirement: Edge Anomaly Tuning Ownership
Deployment-level anomaly tuning SHALL have an explicit owner for edge spike
detection. Operator-visible settings MUST either be propagated into edge add-on
assignments or clearly scoped away from edge spike detection.

#### Scenario: Operator changes spike detector threshold
- **WHEN** an operator updates the deployment anomaly threshold, window, minimum samples, or confirm slots
- **THEN** assigned edge anomaly add-ons SHALL receive equivalent detector params through their effective config
- **OR** the UI and docs SHALL state that those fields affect only central seasonal/capacity behavior and edge spike tuning is assignment-managed

### Requirement: Anomaly Finding Idempotency
A persisted anomaly, seasonal, or capacity finding identity SHALL be deterministic
for a given logical condition so that redelivery and repeated worker runs converge
on one finding instead of accumulating duplicates.

#### Scenario: Redelivered edge verdict does not duplicate
- **GIVEN** an edge anomaly verdict has been persisted
- **WHEN** the same verdict is redelivered (for example, on a JetStream redelivery)
- **THEN** core-elx SHALL recognize it as the same finding via its deterministic identity and SHALL NOT insert a duplicate row

#### Scenario: Repeated central run does not duplicate
- **GIVEN** a sustained capacity-exhaustion or seasonal-breach condition
- **WHEN** consecutive scheduled worker runs evaluate the same condition
- **THEN** the derived finding identity SHALL NOT include per-run wall-clock time
- **AND** the runs SHALL update or dedup one finding rather than create a new finding each run

#### Scenario: Poison verdict is not silently dropped
- **WHEN** a verdict exhausts its redelivery budget without being processed
- **THEN** core-elx SHALL route it to a dead-letter path or raise an operational alert rather than discard it silently

### Requirement: Seasonal Profiling Data Feed
Central seasonal disposition SHALL have an implemented data source that produces
the day-of-week / hour-of-day robust-statistic columns the worker consumes, and
SHALL fail observably when that source returns no profile data.

#### Scenario: Seasonal source returns profile statistics
- **WHEN** the seasonal worker runs its configured profiling query
- **THEN** the query path SHALL produce the `dow`, `hod`, and robust-statistic columns (center/MAD and percentile bounds) the worker reads
- **AND** the bucketing SHALL be aligned to a configured local time zone rather than smearing seasonality across UTC and DST shifts

#### Scenario: Missing profile feed is surfaced
- **WHEN** the profiling query returns rows without the expected profile columns
- **THEN** the seasonal worker SHALL emit a bounded error and operational signal rather than silently producing no verdicts

#### Scenario: Seasonal findings clear
- **GIVEN** a series previously surfaced a central seasonal breach
- **WHEN** later evaluations are within the seasonal baseline
- **THEN** the worker SHALL emit a seasonal clear for that series rather than leaving the finding open indefinitely

### Requirement: Anomaly Identity Partition Scoping
Canonical anomaly identity and any join used to compute a finding SHALL be scoped
to the owning partition, and free-form producer values SHALL NOT be able to forge
or collide canonical keys.

#### Scenario: Series key is partition scoped and collision resistant
- **WHEN** core-elx derives a canonical `series_key` and finding identity from producer-supplied `source_identity`
- **THEN** the identity SHALL incorporate the attested `partition_id`
- **AND** free-form tag, hostname, or IP values SHALL be escaped or hashed before being joined into delimited keys so two distinct series cannot collide onto one identity

#### Scenario: Capacity denominator stays within partition
- **WHEN** core-elx resolves an interface link speed to compute a capacity utilization denominator
- **THEN** the lookup SHALL be constrained to the same partition as the forecast subject

### Requirement: Edge And Central Verdict Correlation
Edge and central verdicts that describe the same canonical series SHALL use
consistent, sanitized subject and key identity so they correlate downstream.

#### Scenario: Re-keyed edge verdict shares central subject form
- **WHEN** core-elx republishes a re-keyed edge anomaly verdict
- **THEN** it SHALL build the publish subject with the same sanitization the central seasonal and capacity emitters use for the same series
- **AND** the subject SHALL NOT contain unescaped delimiters or messaging wildcards that would prevent delivery or correlation
