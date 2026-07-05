# edge-architecture — robust edge anomaly detection

## ADDED Requirements

### Requirement: Edge Robust Dispersion Estimator

The edge anomaly detector SHALL stop self-masking, where a large spike inflates its own
mean/std baseline and hides a subsequent spike. Today the detector (`rust/anomaly-core`) computes
dispersion with Welford O(1) **mean/std** (non-robust). The detector SHALL EITHER (a) replace the
mean/std dispersion with a **robust median/MAD (Hampel) identifier**, OR (b) at minimum
**freeze (withhold) the baseline window updates during a confirmed breach** so the breaching
samples cannot enter the baseline. The detector SHALL **retain** the existing dispersion floors
(absolute + CV), the directional saturation gate for percent gauges (`min_value` 80/80/85 for
cpu/mem/disk), and the confirm-slot hysteresis defined in
`fix-anomaly-engine-semantics-and-delivery` (`Edge Detector Numeric Safety`,
`Anomaly Confirmation Slot Definition`); this change replaces only the dispersion estimator and
does not re-author those guards.

#### Scenario: A spike does not poison its own baseline

- **GIVEN** a series whose recent window contains one large sustained spike, followed by a second spike of similar magnitude
- **WHEN** the robust (median/MAD) detector — or the breach-freeze rule — scores the second spike
- **THEN** the second spike SHALL still breach (it SHALL NOT be masked by the first spike inflating the baseline)

#### Scenario: Existing guards are preserved

- **GIVEN** a cpu/mem/disk percent gauge below its saturation gate (`min_value` 80/80/85)
- **WHEN** the detector scores it under the robust dispersion estimator
- **THEN** the directional saturation gate, the dispersion floors, and the confirm-slot hysteresis SHALL still apply unchanged

### Requirement: Edge Drift Detection Via Two-Sided CUSUM

The edge detector SHALL add a **two-sided CUSUM** over the (deseasonalized, where available)
residual so slow drifts and leaks — which a point z-score cannot see — are detected. The CUSUM
SHALL accumulate signed residual deviations and SHALL signal when either the upward or downward
cumulative sum exceeds a configured decision threshold, complementing (not replacing) the spike
z-score.

#### Scenario: A slow leak is detected that a point z-score misses

- **GIVEN** a series that drifts slowly upward over a long window with no single sample exceeding the z-score threshold
- **WHEN** the two-sided CUSUM accumulates the signed residuals
- **THEN** the detector SHALL signal the drift once the cumulative sum crosses the decision threshold
- **AND** the point-z-score path SHALL remain unaffected for sudden spikes

### Requirement: Edge Deseasonalization From Coarse Hour-Of-Week Baseline

The edge detector SHALL support consuming a **coarse hour-of-week seasonal baseline** (sourced
from the core S-H-ESD seasonal profile). When a baseline is available for a series, the detector
SHALL score the **deseasonalized residual** (value minus the expected seasonal level) rather than
the raw value, so a normal recurring ramp (for example a morning business-hours ramp) does not
false-fire. When no baseline is available the detector SHALL fall back to scoring the raw value
as today.

#### Scenario: Morning ramp does not false-fire when a baseline is present

- **GIVEN** a series with a coarse hour-of-week baseline whose expected level rises during business hours
- **WHEN** the value rises along the expected seasonal level
- **THEN** the detector SHALL score the deseasonalized residual and SHALL NOT breach on the expected ramp

#### Scenario: Cold-start falls back to raw scoring

- **GIVEN** a series with no coarse hour-of-week baseline available
- **WHEN** the detector scores a sample
- **THEN** it SHALL score the raw value (current behavior) and SHALL NOT block on a missing baseline
