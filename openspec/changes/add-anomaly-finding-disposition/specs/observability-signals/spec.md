## ADDED Requirements

### Requirement: Anomaly Finding Disposition Correlation
The system SHALL correlate an edge anomaly finding with the overlapping central
seasonal verdict for the same canonical series and emit a disposition
(`suppress`, `downgrade`, `escalate`, or `pass_through`) at the alert/query layer.
The raw edge finding SHALL be retained regardless of disposition (recall + audit);
disposition SHALL NOT gate persistence of the edge finding.

#### Scenario: Sustained off-baseline spike escalates
- **GIVEN** an edge spike finding for canonical series `S` in window `W`
- **AND** the central seasonal verdict for `S` over the hour overlapping `W` is off-baseline
- **WHEN** the alert engine evaluates the finding
- **THEN** the disposition SHALL be `escalate`
- **AND** the raw edge finding SHALL remain persisted

#### Scenario: Cold-start passes through
- **GIVEN** an edge spike finding for series `S`
- **AND** the central tier reports `insufficient_seasonal_baseline` for `S`
- **WHEN** the alert engine evaluates the finding
- **THEN** the disposition SHALL be `pass_through`
- **AND** the finding SHALL NOT be suppressed on absent seasonal evidence

### Requirement: Disposition Resolution Model
Disposition SHALL only reconcile edge and central judgments where their temporal
resolutions are comparable. A short edge spike SHALL NOT be suppressed solely
because the overlapping hourly seasonal mean is within baseline, because the
hourly mean can dilute a sub-minute spike. Suppression of a recurring spike by a
resolution-matched peak profile MAY be enabled per metric class only after that
peak profile is shown stable.

#### Scenario: Hourly-normal does not silence a short spike
- **GIVEN** an edge spike finding for series `S` in a 30-second window
- **AND** the seasonal verdict for the overlapping hour is `expected` (hourly mean normal)
- **WHEN** the alert engine evaluates the finding
- **THEN** the disposition SHALL be `pass_through`, not `suppress`

#### Scenario: Sustained drift without an edge spike surfaces
- **GIVEN** no edge spike finding for series `S` in hour `H`
- **AND** the central seasonal verdict for `S` in `H` is off-baseline
- **WHEN** the central tier runs
- **THEN** it SHALL surface a low-grade sustained-drift finding for `S`

### Requirement: Seasonal Disposition Emitted For Every Evaluated Series
The central seasonal worker SHALL record a disposition for every evaluated series
and window, including a non-surfacing `normal` disposition, so the correlation
layer always has a verdict to join. A `normal` disposition SHALL NOT emit an
alert or a surfaced `class_uid=2004` finding.

#### Scenario: Normal series still records a verdict
- **GIVEN** the seasonal worker evaluates series `S` and finds it within baseline
- **WHEN** the worker completes the run
- **THEN** it SHALL persist a `normal` disposition keyed by the canonical `series_key` and window
- **AND** it SHALL NOT raise an alert or surface a finding for `S`

### Requirement: Robust Seasonal Statistic
The default seasonal sources SHALL compute baselines with a robust statistic
(`median + MAD`) rather than `mean + stddev`, so a past incident in the history
does not poison the profile.

#### Scenario: Past incident does not hide itself
- **GIVEN** a seasonal cell with five samples, one of which is a prior incident spike
- **WHEN** the baseline is computed for that cell
- **THEN** the central tendency and dispersion SHALL be computed with median and MAD
- **AND** a subsequent spike of similar magnitude SHALL still be classified off-baseline

### Requirement: Seasonal Tier Liveness Gate
The seasonal disposition worker SHALL detect when its disposition NIF is missing
or is the retired implementation and surface a degraded-mode signal, rather than
silently emitting zero verdicts that are indistinguishable from "all normal".

#### Scenario: Missing NIF surfaces degraded mode
- **GIVEN** the live disposition NIF is missing or is the retired `causal_reasoner_nif`
- **WHEN** the seasonal worker runs
- **THEN** it SHALL surface a degraded-mode signal
- **AND** it SHALL NOT report success with zero emitted verdicts as if all series were normal

### Requirement: Anomaly Finding Severity Calibration
`class_uid=2004` findings SHALL map their raw detector score (z / deviation) onto
bounded OCSF severity buckets through a calibration transform, so undisposed or
cold-start findings are not disproportionately Critical.

#### Scenario: Raw score is bucketed
- **GIVEN** an anomaly finding with a raw deviation score far outside the typical range
- **WHEN** the finding severity is assigned
- **THEN** the severity SHALL be a bounded calibrated bucket
- **AND** the calibration SHALL NOT change which findings are emitted (recall is unchanged)

### Requirement: Capacity Forecast Finding Idempotency
Capacity forecast findings SHALL derive their `event_id` from stable forecast
identity (series + horizon), not from per-run wall-clock, so repeated runs of the
same forecast collapse under the `(id, time)` upsert instead of accumulating
duplicate rows.

#### Scenario: Re-running a forecast does not duplicate
- **GIVEN** the capacity forecaster runs twice for the same series and horizon with no underlying change
- **WHEN** both runs persist their findings
- **THEN** the two findings SHALL collapse to a single row under the `(id, time)` upsert
