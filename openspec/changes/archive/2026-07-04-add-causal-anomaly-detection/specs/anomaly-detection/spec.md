## ADDED Requirements

### Requirement: Streaming Statistical Anomaly Detection
The system SHALL detect anomalies in live metric streams by comparing each incoming sample against a per-series learned baseline maintained in a bounded sliding window, without requiring an operator-configured static threshold. Detection SHALL run per-sample as a synchronous, Markovian computation driven by the metric stream.

#### Scenario: Anomalous sample exceeds the learned baseline
- **WHEN** a metric sample arrives for a series whose sliding window is filled
- **THEN** the system SHALL compute a z-score `(sample - mean) / std` using the window mean and sample standard deviation (variance over n−1)
- **AND** SHALL flag the sample as anomalous when the z-score exceeds the configured N-sigma threshold

#### Scenario: Window not yet warmed
- **WHEN** a series' sliding window has fewer than the minimum required samples
- **THEN** the system SHALL NOT emit an anomaly verdict for that series and SHALL continue accumulating baseline samples

### Requirement: Baseline Integrity Under Sustained Anomaly
The system SHALL exclude samples flagged as anomalous from the baseline window so that a sustained surge cannot poison its own baseline and self-mask.

#### Scenario: Sustained flood remains anomalous for its full duration
- **WHEN** a series receives a prolonged run of anomalous samples
- **THEN** the system SHALL NOT push those anomalous samples into the baseline window
- **AND** the baseline mean SHALL remain representative of normal behavior so each flood sample continues to read anomalous until the surge ends

### Requirement: Sustained-Surge Confirmation
The system SHALL require an anomaly to persist across a configurable number of consecutive evaluation slots before raising a finding, and SHALL reset that confirmation counter on any clean sample, so that transient spikes do not generate findings.

#### Scenario: Transient spike is suppressed
- **WHEN** a series produces a single anomalous sample followed by clean samples
- **THEN** the consecutive-anomaly counter SHALL reset and no finding SHALL be raised

#### Scenario: Sustained surge is confirmed
- **WHEN** a series produces anomalous samples across at least the configured number of consecutive slots
- **THEN** the system SHALL raise an anomaly finding for that series

### Requirement: Per-Series Configuration and Defaults
The system SHALL provide per-series configuration for the N-sigma threshold, the consecutive-slot confirmation count, the window size, and the minimum sample count, with platform defaults applied when unset and class-specific defaults available for distinct metric classes (interface throughput, service RED, host resource).

#### Scenario: Defaults applied to a new series
- **WHEN** a metric series is observed for which no explicit configuration exists
- **THEN** the system SHALL apply the platform/class default thresholds rather than requiring operator input before detection can run

### Requirement: Baseline Cold-Start from Aggregated History
The system SHALL seed a new or empty per-series baseline window from the long-horizon hourly continuous aggregates via on-demand query (request/response), and SHALL NOT stream TimescaleDB hypertables to do so.

#### Scenario: Detection useful before a fresh window fills
- **WHEN** the detector starts or first observes a series with an empty window
- **THEN** the system SHALL query that series' recent normal from the hourly continuous aggregate to seed the baseline
- **AND** SHALL transition to live-stream updates once seeded

### Requirement: Bounded Per-Series State
The system SHALL bound the memory used for per-series window state with fixed-capacity windows and SHALL evict idle series so that the working set stays bounded under high series cardinality.

#### Scenario: Idle series evicted
- **WHEN** a series has received no samples for longer than the idle retention period and the series cap is under pressure
- **THEN** the system SHALL evict that series' window state

### Requirement: Restart Resilience
The detector SHALL survive restarts without replaying a stale backlog and without requiring a full re-warm from zero. Its stream consumer SHALL use a live delivery policy (new messages only), and the system SHALL persist a compact per-series state snapshot (recent window samples and confirmation counters) to durable storage so it can be restored on boot.

#### Scenario: Detector restarts with persisted state
- **WHEN** the detector restarts and a per-series snapshot exists
- **THEN** it SHALL restore the series' window state and counters from the snapshot
- **AND** it SHALL resume live consumption without reprocessing a backlog

#### Scenario: Detector restarts without a snapshot
- **WHEN** the detector restarts for a series that has no snapshot
- **THEN** it SHALL cold-start the baseline from the hourly continuous aggregate and SHALL suppress findings for that series until the window re-warms to the minimum sample count

### Requirement: Operator-Managed Detection Configuration
Detection tuning parameters (N-sigma threshold, window size/duration, confirmation-slot count, minimum sample count, and per-metric-class overrides) SHALL be stored in the database, seeded from deployment defaults on first boot, and editable by operators without redeploying. The detector SHALL apply configuration changes without requiring a restart.

#### Scenario: Operator changes a threshold
- **WHEN** an operator edits the N-sigma threshold for a metric class in the configuration store
- **THEN** the detector SHALL pick up the new value on its next configuration refresh and apply it without a restart

#### Scenario: First-boot defaults
- **WHEN** the system starts with no stored detection configuration
- **THEN** it SHALL seed the configuration from deployment (Helm) defaults so detection runs without manual setup

### Requirement: Stateless Reasoning with Externalized Context
The anomaly reasoning step SHALL be a stateless pure function of (context, sample), so that reasoning can be horizontally scaled across replicas without per-series affinity. Per-series state SHALL be held in a separate context engine that owns each series with a single writer (so its update order is well-defined) and SHALL be horizontally scalable across the cluster with automatic failover.

#### Scenario: Reasoning scales without affinity
- **WHEN** reasoning load increases and additional replicas are added
- **THEN** any replica SHALL be able to evaluate any sample given its context
- **AND** samples SHALL NOT need to be routed to a specific replica for reasoning to be correct

#### Scenario: Context owner fails over
- **WHEN** the node owning a series' context becomes unavailable
- **THEN** ownership SHALL be reassigned to another node
- **AND** the new owner SHALL restore context from its checkpoint and resume folding updates without corrupting state

### Requirement: Horizontal Scaling via Cluster Replicas
Analysis capacity SHALL scale by adding control-plane replicas: context ownership SHALL redistribute across the cluster automatically as replicas join or leave, and per-node concurrency SHALL absorb bursts via demand-driven backpressure. The system SHALL NOT require a separate standalone consumer deployment or an external autoscaler to function.

#### Scenario: Replica added
- **WHEN** a new control-plane replica joins the cluster
- **THEN** context ownership SHALL rebalance to include it
- **AND** analysis throughput SHALL increase without manual repartitioning

#### Scenario: Replica lost
- **WHEN** a replica leaves the cluster
- **THEN** its owned context SHALL be reassigned to surviving replicas and restored from checkpoint
- **AND** the system SHALL continue functioning without an external autoscaler
