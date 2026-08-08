## ADDED Requirements

### Requirement: SRQL supports TDengine-backed metric queries
The SRQL engine SHALL support a TDengine backend for raw metric and metric rollup
queries while preserving CNPG-backed execution for non-metric entities.

#### Scenario: Metric query routes to TDengine when enabled
- **GIVEN** TDengine metric backend is enabled
- **WHEN** a client sends a supported `in:timeseries_metrics` query
- **THEN** SRQL generates and executes the equivalent TDengine query
- **AND** returns results in the existing SRQL response shape

#### Scenario: Non-metric query remains on CNPG
- **GIVEN** TDengine metric backend is enabled
- **WHEN** a client sends `in:devices hostname:router`
- **THEN** SRQL executes the query through the existing CNPG-backed path

### Requirement: TDengine metric backend preserves high-value metric filters
The TDengine SRQL backend SHALL support device/resource identity filters,
metric type/name filters, time windows, latest queries, bucketed aggregation,
sorting, and limits for supported metric entities.

#### Scenario: Device metric time window
- **WHEN** a client sends `in:timeseries_metrics device_id:"sr:abc" metric_name:"cpu.usage_percent" time:last_1h`
- **THEN** SRQL constrains the TDengine query by device, metric name, and time
  window

#### Scenario: Bucketed aggregation
- **WHEN** a client sends `in:timeseries_metrics metric_type:"sysmon.cpu" time:last_24h bucket:1h agg:avg`
- **THEN** SRQL returns one-hour average buckets using TDengine query semantics

### Requirement: TDengine SRQL rollout is configurable
The system SHALL allow operators to enable or disable TDengine-backed metric
SRQL without disabling other SRQL entities.

#### Scenario: Rollback to CNPG metric queries
- **GIVEN** TDengine metric backend has been enabled
- **WHEN** the operator disables the TDengine metric backend
- **THEN** SRQL routes metric queries back to the existing CNPG-backed metric
  path where supported
