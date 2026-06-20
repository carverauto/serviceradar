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
and core-elx restarts. A seasonal confirmation slot is one completed evaluation
for one canonical `(source, series_key, dow, hod)` bucket after readiness checks
and detector gates pass; `confirm_slots = N` means N consecutive breaching slots
are required to open a finding, and a clean slot resets the pending count.

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

### Requirement: SNMP Anomaly Target Attribution
An anomaly finding for a metric the agent polls from a remote device SHALL be
attributed to the polled device, not to the agent host that performed the poll.

#### Scenario: SNMP interface anomaly attributes to the polled device
- **GIVEN** an agent polls SNMP interface metrics from a separate network device
- **WHEN** the edge add-on produces an anomaly finding for one of those interface series
- **THEN** the finding `device_uid`, `series_key`, and persisted device identity SHALL resolve to the polled device (and its interface), not the agent host
- **AND** the device-details page for a host that does not itself collect SNMP SHALL NOT show that host's agent's SNMP-of-other-devices findings as its own

### Requirement: Anomaly And Capacity Alerting
Anomaly and capacity findings SHALL be able to generate operator alerts, and that
alerting SHALL be transition-gated and deduplicated so it cannot storm.

#### Scenario: Confirmed anomaly raises one alert
- **GIVEN** a series transitions to a confirmed anomaly-open state
- **WHEN** the alert generator processes anomaly findings
- **THEN** it SHALL raise one alert for that condition and resolve it on the clear transition
- **AND** it SHALL NOT raise an alert for a `pending_anomaly` finding or for each per-sample finding

#### Scenario: Sustained condition does not storm
- **WHEN** the same anomaly or capacity condition persists across many findings or worker runs
- **THEN** the alert generator SHALL coalesce them into a single active alert with a cooldown/suppression window rather than one alert per finding

#### Scenario: Capacity alert fires on a real exhaustion crossing
- **WHEN** a capacity forecast's exhaustion ETA crosses the configured warning horizon
- **THEN** the alert generator SHALL raise a capacity alert
- **AND** it SHALL NOT alert on every re-emitted `projected` forecast that has no horizon crossing

### Requirement: Operator-Actionable Anomaly Presentation
The device-details anomaly and capacity presentation SHALL give an operator enough
identity and context to act, and SHALL be able to show the signal that triggered a
finding.

#### Scenario: Finding row carries actionable identity
- **WHEN** the device-details panel renders an anomaly finding
- **THEN** the row SHALL show a human title, the metric name, the interface/ifIndex for interface findings, and the anomalous value/score
- **AND** the row SHALL be drill-down navigable to a detail view rather than a static, content-free line

#### Scenario: Metric chart reflects the scored signal
- **WHEN** the device-details metric chart renders a per-core or per-series metric for which the detector produced a finding
- **THEN** the chart SHALL be able to show the per-series and short-duration spike the detector scored (not only a cross-series, long-bucket average)
- **AND** the chart's summary min/avg/max SHALL be consistent with the plotted aggregation

#### Scenario: Downsampling preserves extremes
- **WHEN** a chart downsamples a dense series for rendering
- **THEN** it SHALL preserve real minima and maxima (e.g. min/max-envelope downsampling) rather than dropping extremes by fixed-stride decimation or attenuating them by interpolation/smoothing of measured samples

#### Scenario: Findings are locatable on the timeline
- **WHEN** an anomaly or capacity finding exists for a series shown on a chart
- **THEN** the chart SHALL be able to annotate the finding's time (and any configured threshold) on the timeline so the operator can see where it fired

#### Scenario: Axis is readable and correctly unitized
- **WHEN** a series occupies a narrow band high above zero, or carries a known metric unit
- **THEN** the chart SHALL be able to scale to the data band (not only a zero-floored axis) and SHALL label the axis from the metric's unit rather than guessing from the field name

### Requirement: Quantitative Traffic Accuracy
Traffic figures derived from sampled flow data SHALL be quantitatively correct, and
a value labeled as a rate SHALL be a rate.

#### Scenario: Sampled flow is scaled by its sampling rate
- **WHEN** bandwidth, top-N, gauge, or percentile figures are computed from NetFlow/sFlow records that carry a sampling rate
- **THEN** the figures SHALL be scaled by the sampling rate so they reflect true traffic, not the sampled subset

#### Scenario: A rate is divided by its time window
- **WHEN** a value is presented in per-second units (bps, B/s, pps)
- **THEN** it SHALL be the windowed total divided by the window duration, not the raw cumulative window total
- **AND** SNMP interface counter charts SHALL present a derived per-second rate that handles counter wrap/reset as gaps rather than fabricated spikes

#### Scenario: Sampling rate is carried end to end
- **WHEN** a flow exporter reports a sampling rate (NetFlow options/sampler records, IPFIX/v9 sampling IEs, or sFlow)
- **THEN** the collector SHALL capture it and core SHALL persist it on a queryable flow field (not only an unmapped blob)
- **AND** continuous-aggregate rollups SHALL store sampling-scaled volume so historical traffic figures are also correct

### Requirement: Authored Dashboard Query Safety
A user-authored or user-parameterized dashboard SHALL NOT let a viewer read data
outside the dashboard's intended scope or run unbounded queries.

#### Scenario: Variable values cannot rewrite the query
- **WHEN** a dashboard variable value is supplied by a viewer and used in a panel query
- **THEN** the value SHALL be parameterized or escaped and validated against the variable's declared type/allowed set
- **AND** it SHALL NOT be able to change the query's collection (`in:`), filters, or other grammar

#### Scenario: Authored queries are bounded
- **WHEN** an authored panel query runs
- **THEN** it SHALL carry a default time window and a maximum row limit so it cannot trigger an unbounded scan

### Requirement: Query Engine Robustness
The SRQL query engine SHALL not crash on untrusted input and SHALL paginate and
filter deterministically.

#### Scenario: Malformed query does not panic
- **WHEN** a client submits a query with a malformed duration, an out-of-range relative time, or a non-ASCII value
- **THEN** the engine SHALL return a bounded error, not panic the request handler or worker

#### Scenario: Pagination is stable
- **WHEN** a result set is paginated over a non-unique sort key
- **THEN** the engine SHALL append a unique tie-breaker to the ordering so no row is dropped or duplicated across pages

#### Scenario: List and negation filters are correct
- **WHEN** a multi-value list filter (e.g. `discovery_sources`) or a negation filter (`!=`, `not like`) is applied
- **THEN** list membership SHALL use overlap semantics (any-of), an empty list SHALL not silently match all rows, and the row and aggregate paths SHALL return the same population with respect to NULLs

### Requirement: Topology Query Injection Safety
Topology and graph queries SHALL safely encode all attacker-influenceable values.

#### Scenario: Discovered attributes cannot inject Cypher
- **WHEN** a device-reported value (LLDP/CDP port description or system name, SNMP ifAlias, etc.) is used in a Cypher query
- **THEN** it SHALL be fully escaped (including backslashes) or parameterized so it cannot alter the query structure
