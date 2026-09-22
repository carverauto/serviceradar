## ADDED Requirements
### Requirement: Seasonal baseline delivery is bounded per statement and tolerates a failed source
The edge-baseline producer SHALL fetch full hour-of-week profiles for host sources with at most one device per SRQL statement by default, and SHALL deliver every source that fetched successfully even when another source fails. A run with any failed source SHALL record its delivery heartbeat as unhealthy carrying the failed source names, and SHALL log each failure with the source name and reason in the log message body.

#### Scenario: A fleet larger than the statement budget still receives baselines
- **GIVEN** 20 host devices whose combined full-profile statement exceeds the database statement timeout
- **WHEN** the producer runs
- **THEN** it issues one full-profile statement per device
- **AND** every device's 168-bucket profile is delivered

#### Scenario: One failing source does not silence the others
- **GIVEN** the cpu source fetch fails and the memory and interface source fetches succeed
- **WHEN** the producer runs
- **THEN** memory and interface baselines are written to the add-on params
- **AND** the run's heartbeat health event is unhealthy and names `cpu_seasonal`
- **AND** the freshness tripwire reports the failure reason

### Requirement: Central seasonal episodes follow producer cadence
Central seasonal verdict events SHALL carry the evaluation time as their event time, SHALL retain the evaluated bucket window in the seasonal disposition payload, and SHALL be stale-closed only after a window derived from the central producer's cadence (default 150 minutes, operator-overridable), independent of the edge heartbeat window. A clear that resolves no open episode SHALL NOT create an episode row. Verdict reasons SHALL be operator-readable sentences. The production default for seasonal confirm slots SHALL be 2 consecutive buckets.

#### Scenario: A breach that persists across hourly runs stays one open episode
- **GIVEN** a cpu series whose residual z exceeds the threshold for three consecutive hourly buckets
- **WHEN** the worker evaluates each bucket at :47
- **THEN** one episode remains open across the three runs with `last_seen_at` advancing each hour
- **AND** the stale sweep does not close it between runs

#### Scenario: A clear after a stale close is not a phantom episode
- **GIVEN** a central seasonal episode already stale-closed
- **WHEN** a clear verdict arrives for the same finding with no open episode
- **THEN** no new `anomaly_episodes` row is created
- **AND** no OCSF clear transition is emitted

#### Scenario: A single marginal bucket does not surface
- **GIVEN** production defaults
- **WHEN** one hourly bucket's residual z is 3.1 and the next is 1.0
- **THEN** no breach verdict is emitted

### Requirement: Recurring bursts within a series' recent envelope do not reopen spike episodes
The edge detector SHALL support a per-class burst envelope: when a series' lagged raw history holds at least the configured minimum samples, an upward sample at or below `multiplier x quantile(lagged raw history, q)` SHALL NOT breach regardless of its rolling or seasonal z-score, and the verdict reason SHALL state that the sample was within the recent burst envelope. The envelope SHALL be enabled by default only for interface counter rates, SHALL NOT affect downward breaches or CUSUM drift, and SHALL be overridable per metric class through the existing settings projection.

#### Scenario: A periodic bulk transfer opens once and stays silent
- **GIVEN** an interface byte-rate series with a ~14 KB/s median and a 2-sample ~700 KB/s burst every 20 samples
- **WHEN** the detector has warmed up and observes ten further bursts
- **THEN** at most one spike episode opens and no burst after the first reopens it

#### Scenario: A burst larger than the recent envelope still breaches
- **GIVEN** the same series in steady state
- **WHEN** a burst three times the recent burst magnitude arrives for confirm_slots samples
- **THEN** a spike episode opens

#### Scenario: Traffic disappearing still breaches
- **GIVEN** the same series in steady state
- **WHEN** the rate drops far below the rolling center
- **THEN** the envelope does not suppress the downward breach
