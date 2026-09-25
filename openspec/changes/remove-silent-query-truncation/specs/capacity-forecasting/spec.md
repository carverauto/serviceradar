## MODIFIED Requirements

### Requirement: Forecasting Reads Aggregated History, Not Hypertables
The system SHALL read forecasting inputs from the long-horizon hourly/daily continuous aggregates via SRQL (e.g. cpu/memory/disk/process hourly rollups, the interface hourly rollup, and flow traffic 1h/1d rollups). The system SHALL NOT depend on raw per-sample hypertables (which carry only short retention) for the forecasting horizon. For each series in scope, the read MUST cover that series across the forecast horizon. The system MUST NOT take the newest N points globally across every series and treat that slice as the history.

Seasonal baselines that share this history MUST follow the same per-series rule.

#### Scenario: Forecast uses hourly aggregates
- **WHEN** the forecasting job computes a projection over a multi-week horizon
- **THEN** it SHALL source its history from the hourly/daily continuous aggregates rather than the short-retention raw tables

#### Scenario: Every series in scope keeps its horizon
- **WHEN** the number of series times the horizon is larger than a single global point limit
- **THEN** each series in scope SHALL still contribute its history across the horizon
- **AND** the job SHALL NOT keep only the newest points across the estate
