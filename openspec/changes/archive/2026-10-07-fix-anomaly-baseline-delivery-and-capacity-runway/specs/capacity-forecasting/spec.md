## ADDED Requirements
### Requirement: Capped crossings are recorded distinctly from no crossing
The capacity kernel SHALL report the uncapped projected crossing time alongside the capped exhaustion ETA, and the forecasting worker SHALL record a series whose only reason for lacking an ETA is the history-relative extrapolation cap, and whose crossing lies inside the forecast horizon, with skip reason `exhaustion_beyond_history_cap`, carrying the raw crossing time, the observed history span, and the cap in its diagnostics. A capped series whose crossing lies beyond the horizon SHALL be recorded as `outside_forecast_horizon` with the crossing time, and series with no crossing SHALL keep the `no_projected_exhaustion` reason.

#### Scenario: A short but clean upward trend is explainable
- **GIVEN** a disk series with 24 days of history growing 0.57 points per day whose linear crossing of the 80 percent threshold lies 58 days out
- **WHEN** the worker evaluates it with a 90 day horizon
- **THEN** the persisted row has skip reason `exhaustion_beyond_history_cap`
- **AND** its diagnostics carry the 58-day crossing time and the 48-day cap

#### Scenario: A distant crossing is outside the horizon, not history-capped
- **GIVEN** a disk series with 42 days of history whose linear crossing lies 300 days out
- **WHEN** the worker evaluates it with a 90 day horizon
- **THEN** the persisted row has skip reason `outside_forecast_horizon`
- **AND** its diagnostics carry the 300-day crossing time

#### Scenario: A flat series keeps the plain reason
- **GIVEN** a memory series whose projection stays below the threshold for the whole horizon
- **WHEN** the worker evaluates it
- **THEN** the persisted row has skip reason `no_projected_exhaustion`

### Requirement: Runway surfaces show the newest forecast per resource
The Observability Health runway table SHALL, by default, show only forecasts produced within the last 24 hours, one row per resource and metric (the newest), ordered by projected exhaustion. An operator-supplied runway query SHALL be honored verbatim.

#### Scenario: Retired projections do not appear
- **GIVEN** a resource whose last `projected` row is months old and whose current rows are `skipped`
- **WHEN** the Health page loads with the default query
- **THEN** the resource is absent from the runway table

#### Scenario: Hourly refreshes collapse to one row
- **GIVEN** a resource with a `projected` row from each of the last 24 hourly runs
- **WHEN** the Health page loads with the default query
- **THEN** the runway table shows that resource once, with the newest forecast values
