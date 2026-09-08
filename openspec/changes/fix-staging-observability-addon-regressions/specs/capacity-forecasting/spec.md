## ADDED Requirements

### Requirement: Bounded exhaustion projection horizon
Capacity forecasts SHALL only emit a `projected_exhaustion_at` that falls strictly within the forecast horizon window `(forecasted_at, forecasted_at + horizon_seconds]`. A computed threshold-crossing that is at or before `forecasted_at`, or beyond the horizon, SHALL yield `projected_exhaustion_at = nil` (no projected exhaustion), for both the linear and seasonal models.

#### Scenario: Threshold already crossed in-window
- **WHEN** the fitted series has already crossed the exhaustion threshold within the observed window
- **THEN** `projected_exhaustion_at` is `nil` (not the last sample's timestamp) and the row is not presented as a future-dated forecast

#### Scenario: Near-zero slope
- **WHEN** the linear slope is positive but near zero so the threshold crossing computes thousands of years out
- **THEN** `projected_exhaustion_at` is `nil` rather than a date beyond `forecasted_at + horizon_seconds`

### Requirement: Counter-reset rejection for interface utilization forecasts
For interface octet metrics converted to a bounded `utilization_percent`, the forecaster SHALL reject or winsorize samples whose utilization exceeds a sane ceiling (a configurable multiple of 100%) before fitting any model, so that a single SNMP counter wrap/reset cannot poison the projection.

#### Scenario: Counter wrap spike in the series
- **WHEN** one hourly sample reports a utilization far above 100% (a counter wrap/reset artifact) while the rest are ~1%
- **THEN** the spike is excluded from the fit and the `projected_value` stays within a plausible bounded-percentage range

### Requirement: Implausible-projection clamp
A forecast for a bounded-percentage metric SHALL NOT persist a `projected_value` that exceeds a small multiple of the threshold; such a result SHALL be recorded as skipped/clamped with a diagnostic reason rather than rendered as a literal absurd value.

#### Scenario: Runaway projection
- **WHEN** the model projects a utilization_percent value far above the threshold (e.g. > 10× threshold)
- **THEN** the forecast is marked skipped/clamped (not `status=projected` with an 8e8 value)
