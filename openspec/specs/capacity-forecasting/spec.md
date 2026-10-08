# capacity-forecasting Specification

## Purpose

Forecast when a monitored resource will cross its capacity threshold from
aggregated history, record a distinct reason when a series has no ETA, and
show the newest forecast per resource on the health runway.

## Requirements

### Requirement: Resource Capacity Forecasting
The system SHALL forecast future utilization of monitored resources (cpu, memory, disk, and network interfaces) by fitting a trend model over long-horizon aggregated history, and SHALL compute a projected time-to-exhaustion for each resource. Forecasting SHALL run as a scheduled batch job; it SHALL NOT run on the per-sample streaming hot path.

#### Scenario: Disk runway projected
- **WHEN** the capacity forecasting job runs for a disk resource with sufficient history
- **THEN** the system SHALL fit a trend over the resource's hourly aggregate history and SHALL compute a projected exhaustion timestamp (or report no exhaustion within the horizon)

#### Scenario: Insufficient history guard
- **WHEN** a resource has fewer than the minimum required history points
- **THEN** the system SHALL NOT emit a projection for that resource and SHALL record that it was skipped for insufficient history

### Requirement: Forecasting Reads Aggregated History, Not Hypertables
The system SHALL read forecasting inputs from the long-horizon hourly/daily continuous aggregates via SRQL (e.g. cpu/memory/disk/process hourly rollups, the interface hourly rollup, and flow traffic 1h/1d rollups). The system SHALL NOT depend on raw per-sample hypertables (which carry only short retention) for the forecasting horizon.

#### Scenario: Forecast uses hourly aggregates
- **WHEN** the forecasting job computes a projection over a multi-week horizon
- **THEN** it SHALL source its history from the hourly/daily continuous aggregates rather than the short-retention raw tables

### Requirement: Per-Interface Capacity Rollup
The system SHALL provide an interface-grouped hourly aggregate keyed by interface (e.g. `if_index`) so that per-interface link-saturation runway is computable, and SHALL compute interface utilization against the interface's current capacity (link speed) from device inventory.

#### Scenario: Link-saturation runway computed per interface
- **WHEN** the forecasting job projects an interface's throughput forward
- **THEN** it SHALL use the per-interface hourly rollup for that interface
- **AND** SHALL express the projection as a utilization percentage against the interface's current capacity denominator

### Requirement: Forecast Persistence and Confidence
The system SHALL persist per-resource forecasts (trend, projected value at horizon, projected exhaustion time, and a confidence/interval) and SHALL surface projections as estimates with their confidence so operators do not treat them as certainties.

#### Scenario: Forecast stored with confidence
- **WHEN** a projection is produced
- **THEN** the system SHALL persist it with a confidence indicator
- **AND** SHALL make the projected exhaustion time available to the topology/dashboard views that currently expect it

### Requirement: At-Risk Capacity Findings
The system SHALL emit a capacity finding for resources projected to exhaust within the configured warning horizon, routed through the existing causal-engine emission spine so it reaches the standard alerting pipeline.

#### Scenario: Resource projected to exhaust within the warning horizon
- **WHEN** a resource's projected exhaustion time falls within the warning horizon
- **THEN** the system SHALL emit a capacity-forecast verdict for that resource so it is promoted into the events/alerts pipeline

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
