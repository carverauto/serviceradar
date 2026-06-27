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

### Requirement: Edge Spike Peak Forwarding
An edge anomaly finding for a spike SHALL carry the spike's peak magnitude and the
spike time window, so the core can judge the spike at matched resolution rather
than re-deriving it from a diluted hourly aggregate.

#### Scenario: Edge finding carries peak and window
- **GIVEN** the edge detector confirms a spike on series `S`
- **WHEN** it emits the finding
- **THEN** the finding SHALL include the spike peak magnitude and the spike start/end window

### Requirement: Disposition Resolution Model
Disposition of an edge spike SHALL judge the spike's peak magnitude against a
resolution-matched peak profile — the robust hour-of-week aggregate of the
series' per-hour maxima (`timeseries_metrics_hourly.max_value`) — NOT against the
hourly mean, because the mean dilutes a sub-minute spike. A sustained condition
without an edge spike SHALL be judged against the hourly mean profile. Peak-based
suppression SHALL be enabled for a metric class only after that class's peak
profile passes a stability gate; until then the class SHALL pass through.

#### Scenario: Spike judged against the peak profile, not the mean
- **GIVEN** an edge spike finding for series `S` carrying its peak and window
- **AND** the peak profile for the matching `(dow, hod)` cell is stable
- **WHEN** the alert engine evaluates the finding
- **THEN** the disposition SHALL be derived from the spike peak versus the peak profile
- **AND** it SHALL NOT be derived from the hourly mean

#### Scenario: Recurring spike within the normal peak is suppressed
- **GIVEN** an edge spike whose peak is within the series' normal hour-of-week peak range
- **WHEN** the alert engine evaluates the finding
- **THEN** the disposition SHALL be `suppress` or `downgrade`

#### Scenario: Novel spike above the normal peak escalates
- **GIVEN** an edge spike whose peak exceeds the series' normal hour-of-week peak range
- **WHEN** the alert engine evaluates the finding
- **THEN** the disposition SHALL be `escalate`

#### Scenario: Class without a stable peak profile passes through
- **GIVEN** a metric class whose peak profile has not passed the stability gate
- **WHEN** an edge spike for that class is evaluated
- **THEN** the disposition SHALL be `pass_through`

#### Scenario: Sustained drift without an edge spike surfaces
- **GIVEN** no edge spike for series `S` in hour `H`
- **AND** the hourly **mean** profile for `S` in `H` is off-baseline
- **WHEN** the central tier runs
- **THEN** it SHALL surface a low-grade sustained-drift finding for `S`

### Requirement: Robust Peak Profile Stability Gate
Peak disposition SHALL use a robust, safety-biased band over the `(series, hod)`
cell (collapsing only DOW) that ramps with the cell sample count `n`. The band's
constants are calibration; the following invariants are binding. False-suppress
(silencing a real anomaly) is the cardinal error: every uncertain path SHALL
resolve to pass-through or escalate, never to suppress.

- The band SHALL be **two-sided**: a downward excursion outside the escalation band SHALL escalate, never be auto-suppressed.
- The suppression (inner) band scale SHALL be **bounded above by the per-series prior** (`min(s_cell, CAP·s_prior)`), so a poisoned or thin cell cannot widen the suppression region.
- The **cell** center/scale SHALL be `(series, hod)` and SHALL NOT be pooled across `hod` (the no-smear property: a spiky hour does not widen a quiet hour's band). The **prior** SHALL be the **series-overall robust scale** — each series bounded by ~`CAP×` its OWN typical variability — pooled across `hod` intentionally, because it is a min-cap bound (via `min`), never the band center/width, so the cross-`hod` pooling cannot smear. Calibration on real fleet data established that a `(hod)`-class prior (pooling distinct series) is far too wide to bound a poisoned tight cell (idle-series scale ≈ 0.5 vs class scale ≈ 30 ⇒ a `2·30` cap never binds), so the prior MUST be per-series.
- A cold cell (`n < N_min`), an over-dispersed cell (`s_cell > D·s_prior`), or a ceiling-proximity cell (no upward headroom below 100) SHALL pass through.
- The low-`n` margin SHALL be **sigma-relative** (`1 + A/√n`), never an additive raw floor (an absolute floor applies only when the robust scale is ≈ 0).
- A `suppress` verdict SHALL NOT reset the confirm-slot counter.
- Suppression SHALL ship **disabled (report-only)** until the constants are calibrated against real per-cell distributions, with a per-metric-class kill switch and a coverage metric reporting suppression-eligible mass.

#### Scenario: Downward anomaly escalates (two-sided)
- **GIVEN** a stable `(series, hod)` cell and a spike peak far below the escalation band
- **WHEN** the spike is evaluated
- **THEN** the disposition SHALL be `escalate`
- **AND** it SHALL NOT be `suppress`

#### Scenario: Poisoned thin cell cannot widen the suppression band
- **GIVEN** a `(series, hod)` cell with a minority of poisoned high samples
- **AND** a real novel spike above the localized prior's normal range
- **WHEN** the spike is evaluated
- **THEN** the suppression band SHALL be bounded by `CAP·s_prior`
- **AND** the spike SHALL `escalate`, not `suppress`

#### Scenario: Quiet hour is not whitewashed by a spiky neighbor
- **GIVEN** a chronically-spiky hour and a quiet neighboring hour on the same series
- **AND** a real novel spike in the quiet hour
- **WHEN** the spike is evaluated
- **THEN** the prior used SHALL be localized to the quiet `(series, hod)` cell
- **AND** the spike SHALL NOT be suppressed by the spiky hour's scale

#### Scenario: Cold or ceiling-proximity cell passes through
- **GIVEN** a `(series, hod)` cell with `n < N_min`, or whose `q95` leaves no upward headroom below 100
- **WHEN** an edge spike is evaluated
- **THEN** the disposition SHALL be `pass_through`
- **AND** the band SHALL NOT produce an upper bound above 100

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

### Requirement: Disposition-Driven Effective Severity
A finding's surfaced severity SHALL follow its disposition: `suppress` removes it
from the surfaced/alert path, `downgrade` lowers its severity, `escalate` raises
it, and `pass_through` leaves it unchanged. (The raw detector→finding severity
calibration and the capacity `event_id` idempotency are owned by
`fix-anomaly-engine-semantics-and-delivery` (F12, task 23.4) and are out of scope
here.)

#### Scenario: Downgrade lowers surfaced severity
- **GIVEN** an edge finding dispositioned as `downgrade`
- **WHEN** it is surfaced to the alert path and the device-detail panel
- **THEN** its effective severity SHALL be lower than its raw detector severity
- **AND** a `suppress` disposition SHALL remove it from the alert path entirely
