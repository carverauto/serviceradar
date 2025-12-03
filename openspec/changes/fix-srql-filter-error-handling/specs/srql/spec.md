## ADDED Requirements

### Requirement: SRQL filter validation rejects unknown fields with explicit errors
All SRQL query modules MUST reject unknown filter field names with an explicit `InvalidRequest` error that names the unsupported field, rather than silently ignoring the filter and returning unfiltered results.

#### Scenario: Logs query rejects unknown filter field
- **GIVEN** an SRQL query targeting the `logs` entity with a filter on a non-existent field (e.g., `severty:error`)
- **WHEN** the query is executed via `/api/query`
- **THEN** the API returns HTTP 400 with an error message containing `unsupported filter field 'severty'` and does not return any log rows.

#### Scenario: Traces query rejects unknown filter field
- **GIVEN** an SRQL query targeting the `traces` entity with a filter on a non-existent field (e.g., `spn_id:abc`)
- **WHEN** the query is executed via `/api/query`
- **THEN** the API returns HTTP 400 with an error message containing `unsupported filter field 'spn_id'` and does not return any trace rows.

#### Scenario: Services query rejects unknown filter field
- **GIVEN** an SRQL query targeting the `services` entity with a filter on a non-existent field (e.g., `svc_type:http`)
- **WHEN** the query is executed via `/api/query`
- **THEN** the API returns HTTP 400 with an error message containing `unsupported filter field 'svc_type'` and does not return any service rows.

#### Scenario: Pollers query rejects unknown filter field
- **GIVEN** an SRQL query targeting the `pollers` entity with a filter on a non-existent field (e.g., `poller_name:main`)
- **WHEN** the query is executed via `/api/query`
- **THEN** the API returns HTTP 400 with an error message containing `unsupported filter field 'poller_name'` and does not return any poller rows.

#### Scenario: CPU metrics query rejects unknown filter field
- **GIVEN** an SRQL query targeting the `cpu_metrics` entity with a filter on a non-existent field (e.g., `cpu_usage:high`)
- **WHEN** the query is executed via `/api/query`
- **THEN** the API returns HTTP 400 with an error message containing `unsupported filter field 'cpu_usage'` and does not return any CPU metric rows.

#### Scenario: Memory metrics query rejects unknown filter field
- **GIVEN** an SRQL query targeting the `memory_metrics` entity with a filter on a non-existent field (e.g., `mem_usage:high`)
- **WHEN** the query is executed via `/api/query`
- **THEN** the API returns HTTP 400 with an error message containing `unsupported filter field 'mem_usage'` and does not return any memory metric rows.

#### Scenario: Disk metrics query rejects unknown filter field
- **GIVEN** an SRQL query targeting the `disk_metrics` entity with a filter on a non-existent field (e.g., `disk_usage:high`)
- **WHEN** the query is executed via `/api/query`
- **THEN** the API returns HTTP 400 with an error message containing `unsupported filter field 'disk_usage'` and does not return any disk metric rows.

#### Scenario: OTEL metrics query rejects unknown filter field
- **GIVEN** an SRQL query targeting the `otel_metrics` entity with a filter on a non-existent field (e.g., `metric_unit:ms`)
- **WHEN** the query is executed via `/api/query`
- **THEN** the API returns HTTP 400 with an error message containing `unsupported filter field 'metric_unit'` and does not return any OTEL metric rows.

#### Scenario: Timeseries metrics query rejects unknown filter field
- **GIVEN** an SRQL query targeting the `timeseries_metrics` entity with a filter on a non-existent field (e.g., `ts_value:100`)
- **WHEN** the query is executed via `/api/query`
- **THEN** the API returns HTTP 400 with an error message containing `unsupported filter field 'ts_value'` and does not return any timeseries metric rows.

### Requirement: Error messages identify the invalid field and entity context
All filter validation errors MUST include both the unsupported field name and the entity being queried so users can quickly identify and correct their query syntax.

#### Scenario: Error message includes entity context
- **GIVEN** an SRQL query `in:logs unknown_field:value`
- **WHEN** the query is executed
- **THEN** the error message includes context indicating the field is unsupported for logs queries, e.g., `unsupported filter field for logs: 'unknown_field'`.

### Requirement: Valid filter fields continue to function correctly
Fixing the unknown field rejection MUST NOT affect the behavior of valid filter fields; all documented filters MUST continue to work as specified.

#### Scenario: Valid logs filters still work
- **GIVEN** an SRQL query `in:logs severity_text:error service_name:core`
- **WHEN** the query is executed
- **THEN** the query returns only log rows matching both filter conditions.

#### Scenario: Valid traces filters still work
- **GIVEN** an SRQL query `in:traces span_id:abc123 trace_id:def456`
- **WHEN** the query is executed
- **THEN** the query returns only trace rows matching both filter conditions.
