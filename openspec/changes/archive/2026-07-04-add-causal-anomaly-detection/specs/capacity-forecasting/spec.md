## ADDED Requirements

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
