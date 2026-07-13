# capacity-forecasting — deltas for restore-anomaly-alerting-and-surfacing

## ADDED Requirements

### Requirement: Forecast coverage is observable and configurable

The set of forecast sources SHALL be operator-configurable through a reachable path (deployment environment and the Settings UI backed by the persisted forecast configuration), validated against the known source catalog. Operators SHALL be able to see, in product, which sources are enabled and why recent series were skipped (skip reasons with counts); shipped query surfaces SHALL NOT filter on status values the system never writes.

#### Scenario: Opting in interface forecasting
- **GIVEN** an operator who enables the interface source via Settings or deployment configuration
- **WHEN** the next scheduled forecast run executes
- **THEN** interface series are forecast (subject to the standard history and significance gates) without a code change

#### Scenario: Quiet output is explainable
- **GIVEN** a run whose series were all skipped
- **WHEN** an operator views the capacity health surface
- **THEN** the skipped count and top skip reasons are visible instead of an unexplained empty state

## MODIFIED Requirements

### Requirement: Resource Capacity Forecasting

The system SHALL forecast future utilization of monitored resources by fitting a trend model over long-horizon aggregated history, and SHALL compute a projected time-to-exhaustion for each eligible resource. By default, forecasting SHALL cover monotone consumables (memory and disk usage); cpu, interface, and flow sources SHALL be available through the documented opt-in configuration rather than enabled by default, because bursty bounded gauges produce statistically unsound exhaustion projections. Forecasting SHALL run as a scheduled batch job; it SHALL NOT run on the per-sample streaming hot path.

#### Scenario: Disk runway projected
- **WHEN** the capacity forecasting job runs for a disk resource with sufficient history
- **THEN** the system SHALL fit a trend over the resource's hourly aggregate history and SHALL compute a projected exhaustion timestamp (or report no exhaustion within the horizon)

#### Scenario: Insufficient history guard
- **WHEN** a resource has fewer than the minimum required history points
- **THEN** the system SHALL NOT emit a projection for that resource and SHALL record that it was skipped for insufficient history

#### Scenario: Non-default source requires opt-in
- **WHEN** the forecasting job runs with default configuration
- **THEN** cpu, interface, and flow series are not forecast
- **AND** enabling them requires only the documented opt-in configuration, not a code change

### Requirement: At-Risk Capacity Findings

The system SHALL emit a capacity finding for resources projected to exhaust within the configured warning horizon, routed through the analytics prediction emission spine (`signals.analytics.predictions.*`) so it reaches the standard events/alerts pipeline. Emission SHALL be transition-only with run-persistence confirmation: findings are emitted when a resource's confirmed at-risk state changes, not re-emitted every scheduled run.

#### Scenario: Resource projected to exhaust within the warning horizon
- **WHEN** a resource's projected exhaustion time falls within the warning horizon across the required number of consecutive runs
- **THEN** the system SHALL emit a capacity-forecast verdict for that resource so it is promoted into the events/alerts pipeline

#### Scenario: Stable at-risk state does not re-emit
- **GIVEN** a resource already in a confirmed at-risk state
- **WHEN** subsequent runs reach the same conclusion
- **THEN** no additional finding is emitted until the confirmed state changes
