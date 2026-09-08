## ADDED Requirements

### Requirement: MTR SRQL Time Range Queries
SRQL SHALL support explicit relative and absolute date/time range filters for MTR trace history queries.

#### Scenario: Relative time filter on MTR traces
- **GIVEN** `platform.mtr_traces` contains traces inside and outside the last 24 hours
- **WHEN** a client sends `in:mtr_traces time:last_24h sort:time:desc`
- **THEN** SRQL returns only MTR traces whose trace time falls within the last 24 hours
- **AND** results are ordered by trace time descending unless another supported sort is specified

#### Scenario: Absolute time range filter on MTR traces
- **GIVEN** `platform.mtr_traces` contains traces across multiple days
- **WHEN** a client sends an MTR query with an explicit start and end date/time range
- **THEN** SRQL returns only traces with `time` greater than or equal to the start and less than the end
- **AND** the generated SQL uses the `platform.mtr_traces.time` column for filtering

#### Scenario: MTR time filters combine with target and agent filters
- **GIVEN** MTR traces exist for multiple targets and source agents
- **WHEN** a client sends `in:mtr_traces target:example.com agent_id:agent-1 time:last_7d`
- **THEN** SRQL applies the target, agent, and time filters together with implicit AND semantics

### Requirement: MTR SRQL Pagination Stability
SRQL SHALL provide stable ordering for paginated MTR trace queries so browsing retained history does not skip or duplicate traces when multiple rows share the same timestamp.

#### Scenario: Equal timestamps use deterministic tie-breaker
- **GIVEN** multiple MTR traces have the same `time` value
- **WHEN** a client pages through `in:mtr_traces sort:time:desc limit:50`
- **THEN** SRQL applies a deterministic secondary ordering by trace identifier
- **AND** the same trace does not appear on multiple pages for a stable dataset
