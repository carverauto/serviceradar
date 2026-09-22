## ADDED Requirements

### Requirement: Drift anchor requires a mature baseline
The edge drift detector SHALL capture its CUSUM anchor only once the series'
rolling window holds at least `drift_anchor_min_samples` samples, defaulting to
the full `window_size` and never fewer than `min_samples`. The same threshold
SHALL gate the max-age re-anchor.

#### Scenario: Cold start in a trough does not read the ramp as drift
- **GIVEN** an add-on that started with an empty window during a low-traffic period
- **WHEN** the series ramps to its normal level before the window holds `drift_anchor_min_samples` samples
- **THEN** no drift episode SHALL open, because no anchor has been captured

#### Scenario: Operator lowers the threshold
- **WHEN** a profile sets `drift_anchor_min_samples` below `window_size`
- **THEN** the anchor SHALL be captured at that count, but never below `min_samples`

### Requirement: Drift verdicts report the sustained level
A drift verdict SHALL carry `drift_level`, the mean raw value over the run so
far in the metric's units, alongside `drift_target`, `drift_scale` and
`drift_shift_sigma`. Consumers SHALL draw `drift_level` as the sustained level
and SHALL NOT present `drift_target + drift_shift_sigma * drift_scale` as the
level when `drift_level` is present.

#### Scenario: Level equals the mean of the run
- **GIVEN** a series whose values over a confirmed drift run average 115
- **WHEN** the drift episode opens
- **THEN** the verdict's `drift_level` SHALL be 115 within rounding

#### Scenario: Chart draws the reported level
- **GIVEN** a drift finding whose payload carries `drift_level`
- **WHEN** the finding chart renders
- **THEN** the sustained-level reference line SHALL sit at `drift_level`
