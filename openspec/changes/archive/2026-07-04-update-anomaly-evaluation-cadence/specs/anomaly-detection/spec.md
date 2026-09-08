## ADDED Requirements

### Requirement: Metric Metadata-Aware Extraction
The anomaly engine SHALL preserve metric `kind`, `temporality`, `unit`, resource identity, and point attributes through sample extraction so equivalent physical metrics map to the same anomaly series and incompatible values are not mixed in one baseline.

#### Scenario: Gauge metric is evaluated directly
- **GIVEN** a canonical metric point with `kind` `gauge` and unit `%`
- **WHEN** the point is extracted for anomaly detection
- **THEN** the extracted sample SHALL retain the unit, resource identity, metric name, and point attributes
- **AND** the detector MAY evaluate the point value directly

#### Scenario: Cumulative counter is rate-computed
- **GIVEN** a canonical metric point with `kind` `sum`, `temporality` `cumulative`, and `is_monotonic` true
- **WHEN** the point is extracted for anomaly detection
- **THEN** the detector SHALL compute a rate or delta from prior point state before statistical evaluation
- **AND** counter reset handling SHALL prevent a reset from being treated as a negative anomaly spike

#### Scenario: Units partition baselines
- **GIVEN** two metric points with the same resource and metric name but different units
- **WHEN** series identity is computed
- **THEN** the points SHALL NOT share one anomaly baseline

### Requirement: Cadenced Metric Evaluation
The anomaly engine SHALL support evaluating metric series on a configured evaluation cadence that may differ from the raw sample arrival cadence.

#### Scenario: Raw samples are bucketed into one evaluation slot
- **GIVEN** a metric series produces multiple raw samples during one evaluation interval
- **WHEN** the interval closes
- **THEN** the anomaly engine SHALL evaluate one representative bucket value for that series
- **AND** the raw samples SHALL still be persisted through the normal JetStream `event_writer` path

#### Scenario: Default behavior remains per-sample compatible
- **GIVEN** no evaluation interval override is configured
- **WHEN** raw metric samples arrive at the default cadence
- **THEN** the anomaly engine SHALL evaluate with behavior equivalent to the current per-sample path

### Requirement: Spike-Preserving Slot Aggregation
The anomaly engine SHALL aggregate raw samples into evaluation slots using metric-class-specific aggregation modes that preserve operationally meaningful spikes.

#### Scenario: Utilization spike is retained
- **GIVEN** CPU, memory, or disk utilization samples in one evaluation slot
- **WHEN** one raw sample spikes above the learned baseline
- **THEN** the slot value SHALL preserve that spike using a configured spike-preserving aggregation mode such as max

#### Scenario: Aggregation metadata is retained
- **WHEN** the anomaly engine evaluates a bucketed sample
- **THEN** the sample context SHALL include slot start time, slot end time, aggregation mode, and contributing raw sample count

### Requirement: Bounded Ring-Buffer Evaluation State
The anomaly engine SHALL maintain bounded per-series ring-buffer state for active buckets, clean baseline values, confirmation counters, and recent verdict history.

#### Scenario: Clean sample updates compact baseline state
- **WHEN** an evaluation slot is clean
- **THEN** its value SHALL be inserted into the clean baseline ring
- **AND** incremental statistics SHALL be updated without rebuilding the full baseline window

#### Scenario: Anomalous sample is withheld from baseline
- **WHEN** an evaluation slot breaches the anomaly threshold
- **THEN** its value SHALL NOT be inserted into the clean baseline ring
- **AND** the existing baseline statistics SHALL remain representative of normal behavior

### Requirement: Slot-Based Sustained Confirmation
The anomaly engine SHALL count sustained anomaly confirmation over evaluation slots rather than raw samples.

#### Scenario: Confirmation duration follows evaluation cadence
- **GIVEN** an evaluation interval of 10 seconds and `confirm_slots` of 3
- **WHEN** a series breaches for three consecutive evaluation slots
- **THEN** the anomaly engine SHALL confirm the anomaly after approximately 30 seconds

#### Scenario: Clean slot resets confirmation
- **WHEN** a clean evaluation slot arrives after one or more breached slots
- **THEN** the anomaly engine SHALL reset the consecutive anomaly counter

### Requirement: High-Cardinality Shard Ownership
The production anomaly runtime SHALL support shard-owned series state so high-cardinality deployments do not require one long-lived BEAM process per metric series.

#### Scenario: Series state is routed to a shard
- **GIVEN** many metric series are active
- **WHEN** samples arrive for those series
- **THEN** the runtime SHALL route each series to a deterministic shard owner
- **AND** the shard SHALL preserve per-series ordering while owning many series states

#### Scenario: Idle series state is evicted
- **WHEN** a series has not produced samples past the configured idle retention
- **THEN** the shard SHALL evict that series' in-memory state after any required checkpoint has been written

### Requirement: Scale Benchmark Contract
The anomaly engine SHALL include benchmark coverage that separately reports raw sample throughput and detector evaluation throughput.

#### Scenario: Benchmark reports raw and evaluation rates
- **WHEN** the anomaly scale benchmark completes
- **THEN** it SHALL report raw samples/sec, detector evaluations/sec, active series count, baseline window size, rollup factor, concurrency, confirmed anomaly count, and failed series count

#### Scenario: Million-evaluation target is measurable
- **WHEN** the high-cardinality benchmark profile is run
- **THEN** it SHALL measure progress toward approximately 1M detector evaluations/sec using representative baseline windows and metric-class mixes
