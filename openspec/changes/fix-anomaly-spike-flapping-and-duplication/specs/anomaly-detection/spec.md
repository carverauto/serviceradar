## ADDED Requirements

### Requirement: Duplicate producers for one series fold into one episode

When multiple producers (for example, two agents polling the same SNMP target) emit episode transitions for the same canonical series, core ingest SHALL fold them into a single episode stream keyed by the canonical finding identity rather than persisting one episode stream per producer. The fold SHALL be deterministic (transitions apply to the same episode regardless of which producer reported first), multi-producer series SHALL be counted in telemetry, and the platform SHALL surface a configuration-hygiene warning when more than one agent is assigned to poll the same SNMP target.

#### Scenario: Two agents polling one device produce one episode stream
- **GIVEN** two agents polling SNMP target 192.168.10.1 once per minute each, both running the anomaly addon
- **WHEN** both detectors confirm a breach on `ifOutUcastPkts` ifIndex 49 within the same window
- **THEN** exactly one open episode exists for the canonical series
- **AND** transitions from both producers fold into that episode
- **AND** the series is counted in multi-producer telemetry

#### Scenario: Double-polling is visible to operators
- **GIVEN** an SNMP profile whose `agent_ids` assigns two agents to the same `target_query`
- **WHEN** the configuration is evaluated
- **THEN** a configuration-hygiene warning identifies the doubly-polled targets

## MODIFIED Requirements

### Requirement: Baseline Integrity Under Sustained Anomaly
The system SHALL exclude samples flagged as anomalous from the baseline window so that a sustained surge cannot poison its own baseline and self-mask. Withholding SHALL be bounded: when a series has been breaching (or persistently re-breaching after clears against an unchanged baseline) for longer than a configurable adoption horizon, and the new level is stable and not inside a saturation band, the detector SHALL adopt the current level as the rolling baseline, clear any open episode with reason `adopted`, and resume normal detection against the adopted level. Withheld samples SHALL be counted in telemetry so baseline starvation is observable.

#### Scenario: Sustained flood remains anomalous for its full duration
- **WHEN** a series receives a prolonged run of anomalous samples shorter than the adoption horizon
- **THEN** the system SHALL NOT push those anomalous samples into the baseline window
- **AND** the baseline mean SHALL remain representative of normal behavior so each flood sample continues to read anomalous until the surge ends

#### Scenario: Diurnal level shift is adopted instead of flapping forever
- **GIVEN** an interface counter rate series whose level rises from ~15 pkt/s to ~50 pkt/s as part of its daily cycle, with no delivered seasonal baseline
- **WHEN** samples keep breaching or flapping against the frozen night-level baseline beyond the adoption horizon
- **THEN** the rolling baseline SHALL re-anchor to the new level
- **AND** any open episode SHALL clear with reason `adopted`
- **AND** the series SHALL NOT open more episodes against the stale baseline

#### Scenario: Saturated level is never adopted
- **GIVEN** a bounded gauge breaching inside its saturation band
- **WHEN** the adoption horizon elapses
- **THEN** the level SHALL NOT be adopted and the episode SHALL remain open

### Requirement: Detector scales are floored on every path

Every detector path (rolling z, seasonal, and drift/CUSUM) SHALL standardize residuals using a scale protected by the near-zero magnitude-aware floor and per-class dispersion floors. Interface counter rates SHALL have non-zero class dispersion floors (a coefficient-of-variation floor and an absolute rate floor) so that near-idle interfaces cannot produce unbounded standardized scores from operationally trivial rate changes. No emitted finding SHALL carry a score derived from an unfloored or epsilon scale, and all stored scores SHALL be bounded.

#### Scenario: Quiet interface does not produce astronomical scores
- **GIVEN** an interface whose warm-up rate samples are identical (MAD = 0)
- **WHEN** traffic resumes at a nonzero rate
- **THEN** no finding is emitted with score exceeding the configured bound
- **AND** severity is computed from the floored, bounded evidence value

#### Scenario: Near-idle interface blip does not pin the score cap
- **GIVEN** an interface counter rate series with center ≈ 15 pkt/s and clean-sample scale ≈ 7 pkt/s
- **WHEN** a transient burst to a few hundred pkt/s confirms
- **THEN** the standardized score is computed against the floored class scale
- **AND** the stored score does not saturate at the global cap for such a blip

### Requirement: One logical anomaly is one bounded episode end-to-end

The pipeline SHALL represent each logical anomaly (one series, one condition) as a single episode with a deterministic identity derived from the series' finding UID and episode start. Persisted event rows SHALL correspond to lifecycle transitions only (open, severity escalation, clear). The core ingest SHALL maintain an episode registry that folds duplicate or repeated reports — including from producers that predate episode semantics — into the existing episode without creating rows, and SHALL bound persisted rows per finding per hour. A re-open of the same finding within the configured flap window after a clear SHALL reopen the prior episode — incrementing its reopen count and accounting the merge as `flap_merged` — instead of minting a new episode identity, at both the addon and core ingest layers, so that a flapping series is bounded to a small number of episodes per day. Episodes not refreshed within a staleness window SHALL be closed as stale.

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

#### Scenario: Flapping series reopens one episode instead of minting dozens
- **GIVEN** a series that confirms a breach, clears after several minutes, and re-confirms within the flap window
- **WHEN** the re-open transition is processed
- **THEN** the prior episode is reopened with its reopen count incremented
- **AND** the merge is accounted as `flap_merged`
- **AND** the series does not exceed the per-series daily episode bound

### Requirement: Severity is calibrated and bounded

Severity SHALL be computed from bounded evidence values (never a raw accumulator), per-class bands, and practical-significance gates. Practical significance for interface counter rates SHALL include an absolute effect test (minimum absolute rate change, in addition to the relative-change test) so that statistically extreme but operationally trivial changes on near-idle interfaces are capped at Low. Critical SHALL additionally require a class impact test: for bounded gauges, episode peak inside the saturation band; interface counters and icmp SHALL cap at High from statistical detection alone; per-core CPU series SHALL cap at High; edge drift findings SHALL cap at High and open at Medium. Metrics on the detector denylist (default: cpu.frequency_hz) SHALL produce no findings.

#### Scenario: Single-core burst is not a High/Critical page
- **GIVEN** one core of a 32-core host at 94% for three minutes while the host aggregate stays below saturation
- **WHEN** the spike confirms on the per-core series
- **THEN** the finding severity does not exceed High
- **AND** Critical is reserved for host-level series meeting the saturation impact test

#### Scenario: Drift on a low-utilization gauge is not Critical
- **GIVEN** a confirmed drift episode on a cpu series whose value is below the saturation band
- **WHEN** the finding is emitted
- **THEN** severity is at most High regardless of accumulated statistical magnitude

#### Scenario: Near-idle interface blip is not High severity
- **GIVEN** an interface counter rate series whose center is ~15 pkt/s
- **WHEN** a burst to ~400 pkt/s confirms but the absolute change is below the class absolute-effect floor
- **THEN** the finding severity is capped at Low
- **AND** no critical alert is minted from it

### Requirement: Seasonal baselines cover interface counters with per-interface keys

Hour-of-week baselines SHALL be keyed by device, metric name, and if_index so interface counter rates can be deseasonalized per interface. A delivered baseline SHALL contain every populated hour-of-week bucket for the series, not only the most recent bucket. Scoped interface baselines SHALL be delivered to every agent that actually polls the device (resolved from polling assignments, never by equating partition with agent identity). Baseline delivery SHALL be governed: per-agent scoping, top-K active interfaces per device, minimum history gates, and a hard per-agent payload cap with truncation telemetry. Minimum history SHALL be enforced per bucket and per baseline: buckets below the edge's minimum trusted sample count SHALL NOT be delivered, and a baseline whose delivered buckets cover less than a minimum fraction of the hour-of-week cycle SHALL NOT be delivered (the series stays in bounded no-drift silence and is counted in `drift_inactive_no_baseline`). The addon SHALL treat a delivered baseline with a missing or untrusted bucket for the current hour as no-baseline for that evaluation and SHALL report distinct reasons for "no baselines configured", "no bucket for this hour", and "bucket below trust threshold". Baseline delivery scope is independent of central disposition verdict scope. When payload limits truncate coverage, affected series SHALL degrade to no-drift (bounded silence), never to un-deseasonalized drift.

#### Scenario: Per-interface baselines deseasonalize a busy port without silencing a quiet one
- **GIVEN** a 48-port switch where port 4 carries diurnal traffic and port 9 is quiet
- **WHEN** baselines are delivered for the top-K active interfaces
- **THEN** port 4's drift detection standardizes against its own hour-of-week profile
- **AND** ports without baselines have drift inactive

#### Scenario: A one-bucket two-sample baseline is not delivered
- **GIVEN** an hour-of-week aggregate that has accumulated only one bucket with two samples and zero scale for a series
- **WHEN** the baseline producer runs
- **THEN** no baseline is delivered for that series
- **AND** the series is counted in `drift_inactive_no_baseline` telemetry

#### Scenario: Delivered baselines carry the full populated profile
- **GIVEN** a series with three weeks of hourly aggregate history covering most hour-of-week buckets
- **WHEN** the baseline producer delivers its baseline
- **THEN** the payload contains every populated bucket that passes the trust gate, not only the most recent bucket
- **AND** the edge resolves a bucket for hours other than the delivery hour

#### Scenario: Interface baselines reach every polling agent
- **GIVEN** a device whose interfaces are polled by two agents
- **WHEN** scoped interface baselines are delivered
- **THEN** each polling agent's enabled anomaly assignment receives the baselines for that device's top-K interfaces

### Requirement: Detector behavior is verified by harness scenarios and live SLOs

The proof harness SHALL include scenarios for diurnal seasonality, quiet/pinned series, permanent regime change, restart storms, and re-fire cadence, with hard assertions wired as blocking CI gates (including scorecard floors for spike precision and deseasonalized drift false-positive rate, and a global bound on stored scores). The diurnal scenario SHALL exercise the rolling spike path with no delivered seasonal baseline and SHALL assert a bounded number of spike episodes per simulated day, bounded stored scores, and adoption clears instead of unbounded flapping. Rollout SHALL be gated by live SLO checks including fleet-wide anomaly event volume, Critical share, per-series row bounds, and alert-queue overflow counts.

#### Scenario: CI blocks a drift regression
- **GIVEN** a change that reintroduces un-deseasonalized drift on the diurnal scenario
- **WHEN** the harness runs in CI
- **THEN** the scorecard gate fails the build

#### Scenario: Soak gate blocks a noisy rollout
- **GIVEN** a demo soak where anomaly events exceed the fleet-wide daily bound or Critical share exceeds its ceiling
- **WHEN** the phase gate is evaluated
- **THEN** the next rollout phase does not proceed

#### Scenario: CI blocks a spike-path flapping regression
- **GIVEN** a diurnal interface series with no delivered baseline running the rolling spike detector
- **WHEN** the harness simulates several day/night cycles
- **THEN** the scenario fails if spike episodes exceed the per-day bound or if no adoption clear occurs after a sustained level shift
