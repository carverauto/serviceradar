## ADDED Requirements
### Requirement: Edge Anomaly Transition Semantics
The native anomaly add-on SHALL emit edge spike Detection Findings only for
confirmed anomaly state transitions and recovery transitions. It MUST NOT emit
pre-confirmation pending breaches as Detection Findings.

#### Scenario: Pending breach does not create a finding
- **GIVEN** an edge anomaly series has `confirm_slots` set to 5
- **WHEN** the first through fourth consecutive evaluation slots breach the threshold
- **THEN** the add-on SHALL update its per-series confirmation state
- **AND** it SHALL NOT emit an OCSF Detection Finding for those pending breaches

#### Scenario: Confirmed anomaly opens once
- **GIVEN** an edge anomaly series has reached its configured confirmation count
- **WHEN** the series transitions from inactive to anomalous
- **THEN** the add-on SHALL emit one anomaly-open Detection Finding for that series
- **AND** additional breached slots while the series remains active SHALL NOT emit duplicate open findings

#### Scenario: Active anomaly clears
- **GIVEN** an edge anomaly series has an active anomaly-open state
- **WHEN** a later evaluation slot is clean
- **THEN** the add-on SHALL emit an anomaly-clear Detection Finding for that same canonical series
- **AND** it SHALL reset the active anomaly state for future transitions

### Requirement: Edge Anomaly Telemetry Delivery Resilience
The native anomaly add-on SHALL keep metric-feed scoring independent from native
telemetry stream availability. Agent telemetry reconnects MUST receive future
verdicts without restarting the add-on process.

#### Scenario: Telemetry stream reconnects
- **GIVEN** the agent has opened the anomaly add-on native telemetry stream
- **AND** that stream disconnects while the add-on process remains running
- **WHEN** the agent opens a new native telemetry stream
- **THEN** future anomaly-open, anomaly-clear, and capacity-shed records SHALL be delivered on the new stream

#### Scenario: Telemetry receiver lags
- **GIVEN** the native telemetry receiver is disconnected or slower than anomaly record production
- **WHEN** the add-on processes metric-feed frames
- **THEN** metric-feed acknowledgement SHALL NOT wait indefinitely for telemetry delivery
- **AND** dropped telemetry SHALL be counted or reported through bounded operational diagnostics

### Requirement: Edge Anomaly Config Guards
The native anomaly add-on SHALL reject or correct detector configuration that
would make scoring permanently unavailable.

#### Scenario: Minimum samples exceeds window size
- **WHEN** an anomaly add-on assignment config sets `min_samples` greater than `window_size`
- **THEN** the config SHALL be rejected or normalized before scoring starts
- **AND** the add-on SHALL report a bounded configuration error rather than silently staying in `insufficient_baseline`

#### Scenario: Unset numeric knobs do not brick the add-on
- **GIVEN** an anomaly add-on assignment leaves numeric detector knobs unset
- **WHEN** core seeds and transmits the effective config
- **THEN** it SHALL omit the unset keys or send numeric/null values, never empty strings
- **AND** the add-on SHALL coerce empty or absent optional knobs to their defaults rather than rejecting the config and crash-looping into a permanent circuit-open state

#### Scenario: Add-on stops promptly on request
- **GIVEN** the agent supervisor requests the anomaly add-on to stop or restart
- **WHEN** the add-on receives the shutdown
- **THEN** its shutdown SHALL return within the supervisor grace window so the process is not SIGKILLed
- **AND** repeated reconcile-driven restarts SHALL NOT corrupt the warm baseline checkpoint

#### Scenario: Declared resource bounds are enforced
- **WHEN** the agent launches the anomaly add-on
- **THEN** the add-on process SHALL run under its declared resource slice with the configured memory and task ceilings applied
- **AND** if the bounds cannot be applied, the agent SHALL surface an operational signal rather than running the add-on unbounded in the base-agent cgroup

### Requirement: Edge Detector State Bounds
The native anomaly add-on SHALL bound all per-series detector state and reclaim
state for series that are no longer active, so that a long-lived process and
high-cardinality or churning series cannot grow memory without bound.

#### Scenario: Counter state is capacity bounded
- **WHEN** the add-on rate-normalizes cumulative counter series
- **THEN** the per-counter state map SHALL be subject to the same `max_series` capacity bound as the per-series detector map
- **AND** this bound SHALL apply both during live scoring and when restoring a checkpoint

#### Scenario: Stale series are evicted
- **WHEN** a tracked series has not produced a sample within the configured staleness window
- **THEN** the add-on SHALL evict that series and counter state so its capacity slot is reclaimed for active series
- **AND** the add-on SHALL NOT permanently shed all new series once the lifetime distinct-series count reaches `max_series`

#### Scenario: Capacity-shed diagnostics cover all state
- **WHEN** the add-on reports a capacity-shed diagnostic
- **THEN** the diagnostic SHALL reflect both the per-series and per-counter state sizes against the configured bound

### Requirement: Edge Metric-Feed Task Lifecycle
The native anomaly add-on SHALL run at most one scoring task per add-on instance
and SHALL remain scoreable after a transient internal panic.

#### Scenario: Metric feed reopens
- **GIVEN** an add-on scoring task is running for an open metric feed
- **WHEN** the agent opens a new metric-feed stream against the same running add-on
- **THEN** the add-on SHALL abort or replace the prior scoring task
- **AND** two scoring tasks SHALL NOT concurrently mutate the engine state or the checkpoint file

#### Scenario: Internal panic does not permanently disable scoring
- **WHEN** scoring panics while holding the engine lock
- **THEN** the add-on SHALL recover and resume scoring on subsequent frames
- **AND** a single panic SHALL NOT poison shared state such that all future scoring is permanently disabled

### Requirement: Agent Anomaly Delivery Self-Healing
The agent host SHALL keep anomaly metric-feed and telemetry delivery alive across
recoverable stream and process faults without requiring an operator configuration
change, and SHALL NOT report a delivering add-on as healthy while it is silently
not delivering.

#### Scenario: Drain stream closes while the add-on is alive
- **GIVEN** the agent is draining the add-on telemetry or metric-feed stream
- **WHEN** that stream closes or errors while the add-on process remains running
- **THEN** the agent SHALL re-establish the stream with bounded backoff
- **AND** the stream-loss condition SHALL be reported through operational diagnostics rather than silently swallowed

#### Scenario: Circuit-broken add-on recovers
- **GIVEN** an add-on has tripped its restart circuit breaker after a crash storm
- **WHEN** a cooldown period elapses
- **THEN** the agent SHALL re-arm the breaker and attempt to restart the add-on without an operator configuration change
- **AND** an add-on stuck circuit-open SHALL surface as a health failure, not as healthy

### Requirement: Edge Detector Numeric Safety
The native anomaly detector SHALL NOT emit breaches that are artifacts of
degenerate statistics.

#### Scenario: Near-constant series does not auto-breach
- **GIVEN** a series whose recent values are constant or near-constant and no dispersion floor is configured for its profile
- **WHEN** the series produces a small nonzero deviation
- **THEN** the detector SHALL NOT classify it as a breach solely because the standard deviation is near zero
- **AND** this protection SHALL apply to rate-normalized counter series, which use the default profile

#### Scenario: Short windows produce defined statistics
- **WHEN** detector statistics are computed over a window of fewer than two samples
- **THEN** the computation SHALL return a defined, non-breaching result rather than `NaN`, infinity, or a panic

### Requirement: Anomaly Confirmation Slot Definition
Edge spike detection and central seasonal anomaly detection SHALL use the same
`confirm_slots` semantics so operator tuning has one meaning across detector
surfaces.

#### Scenario: Consecutive breaches open one finding
- **GIVEN** a canonical metric series has `confirm_slots = N`
- **WHEN** N consecutive completed evaluation slots for that series breach after readiness checks and detector gates pass
- **THEN** the detector SHALL transition the series from inactive or pending to active/open
- **AND** it SHALL emit exactly one anomaly-open finding for that confirmed transition

#### Scenario: Clean slot resets pending confirmation
- **GIVEN** a canonical metric series has fewer than N consecutive breaching slots accumulated
- **WHEN** a later completed evaluation slot for that series is clean
- **THEN** the detector SHALL reset the pending confirmation count for that series to zero
- **AND** it SHALL NOT emit an anomaly-clear finding unless the series was already active/open

#### Scenario: Active series clears once
- **GIVEN** a canonical metric series is active/open
- **WHEN** later completed evaluation slots continue to breach
- **THEN** the detector SHALL NOT emit duplicate anomaly-open findings
- **WHEN** the first later completed evaluation slot is clean
- **THEN** the detector SHALL transition the series to inactive and emit one anomaly-clear finding
