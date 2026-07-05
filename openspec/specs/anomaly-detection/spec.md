# anomaly-detection

## Purpose

Define the production anomaly-detection contract for ServiceRadar: edge streaming detection, central seasonal/capacity disposition, bounded episode semantics, severity governance, operator configuration, and UI/verification expectations.
## Requirements
### Requirement: Drift detection requires reference context

The edge drift detector SHALL operate per metric class in one of three modes — `off`, `deseasonalized_only`, or `always` — and in `deseasonalized_only` mode SHALL evaluate drift only against a delivered hour-of-week seasonal center. A series without a delivered baseline SHALL have no drift detection, and the detector SHALL count such series in telemetry rather than falling back to a fixed anchor. Metric classes with strong diurnal patterns (SNMP interface counter rates, cpu.usage_percent, memory.used_percent) SHALL default to `deseasonalized_only`.

#### Scenario: Diurnal traffic with no baseline produces no drift findings
- **GIVEN** an SNMP interface counter rate series with a 10× day/night traffic cycle and no delivered seasonal baseline
- **WHEN** traffic declines every evening for 14 days
- **THEN** zero drift findings are emitted
- **AND** the series is counted in `drift_inactive_no_baseline` telemetry

#### Scenario: Deseasonalized drift detects a real sustained shift
- **GIVEN** the same series with a delivered hour-of-week baseline
- **WHEN** traffic sustains at 2× its seasonal expectation for its hour
- **THEN** exactly one drift episode opens

### Requirement: Drift findings follow an episode lifecycle

Drift detection SHALL use latch-and-confirm alarm semantics and an open/clear episode lifecycle equivalent to the spike path. Crossing the decision interval SHALL NOT emit a finding; confirmation SHALL require continued accumulation to a confirm threshold within a bounded window and a minimum estimated shift size. An open drift episode SHALL emit at most: one open record, severity-escalation updates, a bounded still-open heartbeat, and one clear record. The detector SHALL clear either on sustained recovery or by adopting the new level as baseline after a bounded duration, re-anchoring the reference; adoption SHALL be blocked while a bounded gauge is inside its saturation band. A permanent level shift SHALL produce exactly one open/clear pair, never a recurring alarm stream.

#### Scenario: Regime change produces one episode
- **GIVEN** a series in `always` drift mode whose level permanently steps +3σ
- **WHEN** the shift confirms
- **THEN** exactly one drift-open record is emitted
- **AND** after the adoption window, exactly one clear record with reason "level adopted as new baseline"
- **AND** no further drift findings occur on the new level

#### Scenario: Transient wobble never confirms
- **GIVEN** a series whose accumulator crosses the decision interval once then decays
- **WHEN** the confirm threshold is not reached within the confirm window
- **THEN** no finding is emitted and the accumulator resets silently

### Requirement: Detector scales are floored on every path

Every detector path (rolling z, seasonal, and drift/CUSUM) SHALL standardize residuals using a scale protected by the near-zero magnitude-aware floor and per-class dispersion floors. No emitted finding SHALL carry a score derived from an unfloored or epsilon scale, and all stored scores SHALL be bounded.

#### Scenario: Quiet interface does not produce astronomical scores
- **GIVEN** an interface whose warm-up rate samples are identical (MAD = 0)
- **WHEN** traffic resumes at a nonzero rate
- **THEN** no finding is emitted with score exceeding the configured bound
- **AND** severity is computed from the floored, bounded evidence value

### Requirement: One logical anomaly is one bounded episode end-to-end

The pipeline SHALL represent each logical anomaly (one series, one condition) as a single episode with a deterministic identity derived from the series' finding UID and episode start. Persisted event rows SHALL correspond to lifecycle transitions only (open, severity escalation, clear). The core ingest SHALL maintain an episode registry that folds duplicate or repeated reports — including from producers that predate episode semantics — into the existing episode without creating rows, and SHALL bound persisted rows per finding per hour. Episodes not refreshed within a staleness window SHALL be closed as stale.

#### Scenario: Stale producer re-fire storm is collapsed at ingest
- **GIVEN** an addon that emits one confirmed-open report per evaluation for the same series
- **WHEN** 5,000 reports arrive in one hour
- **THEN** at most the per-finding hourly row bound is persisted
- **AND** the episode's occurrence count reflects the folded reports
- **AND** folds are visible in governor telemetry

#### Scenario: Crashed addon cannot leak open episodes
- **GIVEN** an open episode whose producer stops reporting
- **WHEN** the staleness window elapses
- **THEN** the episode is closed with status `stale_closed`

### Requirement: Severity is calibrated and bounded

Severity SHALL be computed from bounded evidence values (never a raw accumulator), per-class bands, and practical-significance gates. Critical SHALL additionally require a class impact test: for bounded gauges, episode peak inside the saturation band; interface counters and icmp SHALL cap at High from statistical detection alone; per-core CPU series SHALL cap at High; edge drift findings SHALL cap at High and open at Medium. Metrics on the detector denylist (default: cpu.frequency_hz) SHALL produce no findings.

#### Scenario: Single-core burst is not a High/Critical page
- **GIVEN** one core of a 32-core host at 94% for three minutes while the host aggregate stays below saturation
- **WHEN** the spike confirms on the per-core series
- **THEN** the finding severity does not exceed High
- **AND** Critical is reserved for host-level series meeting the saturation impact test

#### Scenario: Drift on a low-utilization gauge is not Critical
- **GIVEN** a confirmed drift episode on a cpu series whose value is below the saturation band
- **WHEN** the finding is emitted
- **THEN** severity is at most High regardless of accumulated statistical magnitude

### Requirement: Emission is governed with no silent drops

The addon SHALL enforce a per-series cooldown between non-clear emissions and a per-addon emission budget per push tick with priority ordering (clears and high-severity opens first). Budget overflow SHALL coalesce into an auditable shed rollup record carrying per-class counts and top offending series. The core SHALL emit an operational flood event when anomaly ingest rate exceeds a threshold. Every detected condition SHALL be traceable: an episode record, a fold into an open episode, or a counted shed record.

#### Scenario: Mass event coalesces instead of flooding
- **GIVEN** 400 interfaces alarming simultaneously at one site
- **WHEN** the per-addon budget is exceeded in a push tick
- **THEN** the highest-priority opens are emitted individually
- **AND** the remainder is summarized in one shed rollup record with counts and top series
- **AND** no detection is dropped without a telemetry trace

### Requirement: Seasonal baselines cover interface counters with per-interface keys

Hour-of-week baselines SHALL be keyed by device, metric name, and if_index so interface counter rates can be deseasonalized per interface. Baseline delivery SHALL be governed: per-agent scoping, top-K active interfaces per device, minimum history gates, and a hard per-agent payload cap with truncation telemetry. Baseline delivery scope is independent of central disposition verdict scope. When payload limits truncate coverage, affected series SHALL degrade to no-drift (bounded silence), never to un-deseasonalized drift.

#### Scenario: Per-interface baselines deseasonalize a busy port without silencing a quiet one
- **GIVEN** a 48-port switch where port 4 carries diurnal traffic and port 9 is quiet
- **WHEN** baselines are delivered for the top-K active interfaces
- **THEN** port 4's drift detection standardizes against its own hour-of-week profile
- **AND** ports without baselines have drift inactive

### Requirement: Operator configuration reaches the edge detector

Anomaly detection settings edited in the Settings UI SHALL be projected onto the anomaly addon profile under a reserved `managed` params sub-key so they take effect at the edge within one config poll interval, with per-metric-class knobs (mode, thresholds, floors, severity overrides, denylist, emission governance). Operator-explicit top-level profile parameters SHALL take precedence over projected managed values. The config projector and baseline producer SHALL own disjoint params keys (`managed` vs `seasonal_baselines`) and SHALL preserve each other's payloads. Kill switches SHALL exist per class and globally, at the addon, projection, and ingest layers.

#### Scenario: Raising a per-class threshold changes edge behavior
- **GIVEN** an operator raising the interface-class drift confirm threshold in Settings
- **WHEN** the projector runs and the agent polls config
- **THEN** the edge detector applies the new threshold without an addon redeploy

### Requirement: Host-level aggregates are the alerting unit for multi-instance metrics

For metrics emitted per hardware instance (per-CPU-core gauges), the detector SHALL evaluate a synthesized host-level aggregate series (mean utilization and count/fraction of instances above the saturation gate) as the primary, Critical-eligible alerting series. Per-instance series MAY still be detected but SHALL be severity-capped below Critical and attached as context rather than paged independently.

#### Scenario: One busy core does not page
- **GIVEN** a 32-core host where one core sustains 94% while the host aggregate stays near 5%
- **WHEN** detection evaluates the host
- **THEN** the host-aggregate series produces no High/Critical finding
- **AND** any per-core finding is capped below Critical

#### Scenario: Host-wide saturation is detected on the aggregate
- **GIVEN** a host where most cores sustain above the saturation gate for the required duration
- **WHEN** detection evaluates the host aggregate
- **THEN** a finding opens on the host-level series and is Critical-eligible

### Requirement: Capacity forecasting is restricted to sound targets

Capacity runway findings SHALL be emitted by default only for monotone consumable resources (disk usage, memory working set), SHALL require trend-significance gates (minimum history relative to the extrapolation horizon, robust slope confidence interval excluding zero, projection gated on the prediction-interval lower bound, persistence across consecutive runs), and SHALL forecast a sustained statistic rather than raw samples. Bursty mean-reverting gauges (cpu.usage_percent, interface utilization) SHALL be excluded by default. Runway findings SHALL follow episode semantics — emitted on state transitions only, never re-emitted per evaluation run for unchanged state — and SHALL be attributed to the actual device (never a partition placeholder). Operator-configured model and threshold values SHALL be honored by every run.

#### Scenario: Bursty CPU gauge produces no runway finding
- **GIVEN** a host whose CPU averages 6% with brief bursts to 90% and ~7 days of history
- **WHEN** the capacity worker evaluates the series with default configuration
- **THEN** no projected-crossing finding is emitted for cpu.usage_percent

#### Scenario: Disk trending to full produces one refreshed finding
- **GIVEN** a disk series with a statistically significant upward trend crossing its threshold within the horizon
- **WHEN** consecutive forecast runs confirm the projection
- **THEN** one runway episode exists, refreshed in place, and clears when the trend retreats

#### Scenario: Unchanged forecasts do not re-emit
- **GIVEN** a fleet of series whose forecast state is unchanged since the previous hourly run
- **WHEN** the capacity worker completes a run
- **THEN** no per-series verdict events are emitted for the unchanged series

#### Scenario: Interface forecasts attribute to the device
- **GIVEN** a projected finding for an interface utilization series
- **WHEN** the finding is persisted
- **THEN** its device attribution is the polled device (optionally qualified by if_index), not a partition key

### Requirement: Findings are legible to operators

Finding surfaces SHALL render decoded series identity (partition, metric class, metric family, device identity, interface index, tags) rather than raw hex-encoded series keys. Metric-context charts SHALL render the finding-time marker when it falls within the fetched window and SHALL state explicitly when it does not. Capacity surfaces SHALL label the projected crossing time as a projection, never as an observation time.

#### Scenario: Finding modal shows decoded identity
- **GIVEN** an anomaly finding whose series key encodes class=sysmon, family=cpu, identity=k8s-cp2-worker1, tag core_id=20
- **WHEN** the operator opens the finding modal
- **THEN** the modal displays the decoded device, metric, and core label instead of hex segments

#### Scenario: Out-of-window marker is explained
- **GIVEN** a capacity finding whose projected crossing lies outside the displayed chart range
- **WHEN** the metric context renders
- **THEN** the panel states the marker time is outside the window instead of silently omitting it

### Requirement: Detector behavior is verified by harness scenarios and live SLOs

The proof harness SHALL include scenarios for diurnal seasonality, quiet/pinned series, permanent regime change, restart storms, and re-fire cadence, with hard assertions wired as blocking CI gates (including scorecard floors for spike precision and deseasonalized drift false-positive rate, and a global bound on stored scores). Rollout SHALL be gated by live SLO checks including fleet-wide anomaly event volume, Critical share, per-series row bounds, and alert-queue overflow counts.

#### Scenario: CI blocks a drift regression
- **GIVEN** a change that reintroduces un-deseasonalized drift on the diurnal scenario
- **WHEN** the harness runs in CI
- **THEN** the scorecard gate fails the build

#### Scenario: Soak gate blocks a noisy rollout
- **GIVEN** a demo soak where anomaly events exceed the fleet-wide daily bound or Critical share exceeds its ceiling
- **WHEN** the phase gate is evaluated
- **THEN** the next rollout phase does not proceed

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

### Requirement: DeepCausality Authoritative Reasoner
Production anomaly evaluation SHALL use the DeepCausality-backed `CausalReasoner` as the authoritative rolling anomaly reasoner for equivalent metric anomaly verdicts.

#### Scenario: Production anomaly verdict uses one reasoner
- **WHEN** the anomaly pipeline evaluates a metric sample for rolling-z anomaly detection
- **THEN** the verdict SHALL be produced by the DeepCausality-backed `CausalReasoner`
- **AND** production code SHALL NOT route equivalent samples through a second hand-rolled detector implementation

#### Scenario: Future detector implementation requires explicit design
- **WHEN** a new implementation would produce equivalent rolling anomaly verdicts outside `CausalReasoner`
- **THEN** it SHALL require an approved OpenSpec change that explains why the DeepCausality reasoner cannot be extended

### Requirement: Incremental Rolling Reasoner State
The DeepCausality reasoner SHALL support compact rolling state using a bounded clean window tail and Welford accumulator so rolling evaluation is O(1) with respect to baseline window size.

#### Scenario: Clean sample advances compact state
- **GIVEN** a reasoner context containing `rolling_acc`, `window_tail`, and `window_size`
- **WHEN** a sample is evaluated and does not breach the rolling threshold
- **THEN** the verdict SHALL include the next `rolling_acc`
- **AND** the verdict SHALL include a `window_tail` with the sample admitted in order
- **AND** the tail SHALL evict the oldest clean value when it exceeds `window_size`

#### Scenario: Breached sample is withheld from compact state
- **GIVEN** a reasoner context with an established clean baseline
- **WHEN** a sample breaches the rolling threshold
- **THEN** the verdict SHALL mark the sample as excluded from the baseline
- **AND** the next `rolling_acc` and `window_tail` SHALL NOT include the breached sample value

#### Scenario: Sample variance matches existing semantics
- **GIVEN** a compact rolling accumulator with at least two clean values
- **WHEN** the reasoner computes rolling standard deviation
- **THEN** it SHALL use sample variance with denominator `count - 1`
- **AND** its z-score decision SHALL match the two-pass baseline-list oracle within the configured tolerance

#### Scenario: Large counters do not collapse variance
- **GIVEN** a window of large-magnitude values such as monotonic counter rates near `1e9`
- **WHEN** rolling variance is computed incrementally
- **THEN** the computed standard deviation SHALL remain numerically stable
- **AND** it SHALL not collapse to zero when the two-pass oracle reports non-zero variance

### Requirement: Batched Reasoner Entry Point
The DeepCausality reasoner SHALL provide a batched NIF entrypoint for evaluating many independent series state transitions in one call.

#### Scenario: Batched results preserve input order
- **GIVEN** a batch of reasoner inputs containing independent context/sample pairs
- **WHEN** `reason_batch` evaluates the batch
- **THEN** it SHALL return one result for each input
- **AND** results SHALL appear in the same order as the inputs

#### Scenario: Per-series order remains a caller guarantee
- **GIVEN** multiple samples for the same series
- **WHEN** the caller batches those samples
- **THEN** the caller SHALL preserve per-series order before invoking `reason_batch`
- **AND** the reasoner SHALL return each next-state value needed by the caller to continue that ordered series

#### Scenario: Scheduler choice is benchmark-gated
- **WHEN** the tuned batch size can exceed the normal NIF scheduler budget
- **THEN** the batched entrypoint SHALL run as a DirtyCpu NIF
- **AND** benchmark output SHALL record the chosen batch size and scheduler mode

### Requirement: Native Shard Runtime State
The anomaly pipeline SHALL support shard-local native reasoner resources that keep compact rolling state in Rust and return only sparse anomaly state-change events for the streaming hot path.

#### Scenario: Runtime state stays shard local
- **GIVEN** a shard resource has evaluated a series with a compact context
- **WHEN** later samples for the same series arrive on the same shard
- **THEN** the caller MAY omit the context
- **AND** the native resource SHALL continue from the stored Welford accumulator, bounded clean tail, confirmation counter, and active anomaly state

#### Scenario: Sparse state-change events are emitted
- **GIVEN** a series is currently inactive
- **WHEN** a sample produces a confirmed anomalous verdict
- **THEN** the shard runtime SHALL emit an anomaly-open event
- **AND** repeated anomalous samples for the same active series SHALL NOT emit duplicate open events
- **AND** a later clean verdict SHALL emit one clear event and mark the series inactive

#### Scenario: Compact tuple input avoids per-sample maps
- **WHEN** the hot shard path receives a batch of scalar metric samples
- **THEN** it SHALL pass compact tuple inputs across the NIF boundary
- **AND** those inputs SHALL include only the sample index, series identity, optional first-context, scalar value, and timestamp

### Requirement: Parity and Cleanup Gate
The compact DeepCausality path SHALL pass parity, drift, and benchmark gates before the temporary compact evaluator is removed.

#### Scenario: Incremental path is compared with two-pass oracle
- **WHEN** randomized parity tests run over finite streams, eviction windows, and threshold settings
- **THEN** incremental compact-state verdicts SHALL match the two-pass oracle for readiness, breach state, z-score tolerance, inclusion/exclusion, and confirmation counters

#### Scenario: Compact evaluator is removed after replacement
- **WHEN** the DeepCausality compact path meets correctness and throughput acceptance
- **THEN** the hand-rolled compact evaluator SHALL be deleted
- **AND** benchmark modes SHALL exercise the DeepCausality per-sample and batched paths instead
