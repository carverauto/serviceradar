## ADDED Requirements

### Requirement: Telemetry identifier normalization in queries

SRQL SHALL normalize `trace_id`, `span_id`, and `parent_span_id` filter values
before comparison: case-fold hexadecimal input to lowercase and reject values
that are not 32-char (trace) or 16-char (span) hex with a clear error instead
of silently matching nothing. Empty-string id filters SHALL be rejected.

#### Scenario: Uppercase input still matches

- **GIVEN** spans stored with lowercase hex trace ids
- **WHEN** a client sends `in:traces trace_id:"6D88848D08854D6AD1561D510041D03C"`
- **THEN** the query SHALL match the stored lowercase rows

#### Scenario: Malformed id is an error, not an empty result

- **WHEN** a client sends `in:logs trace_id:"not-a-trace-id"`
- **THEN** SRQL SHALL return a validation error identifying the malformed
  identifier

#### Scenario: Empty id filter is rejected

- **WHEN** a client sends `in:logs trace_id:""`
- **THEN** SRQL SHALL return a validation error rather than an unfiltered or
  never-matching query

### Requirement: Span retrieval for a trace

SRQL SHALL support fetching all spans of a trace efficiently:
`in:traces trace_id:<hex>` SHALL return every span row for the trace
(timestamp, span_id, parent_span_id, name, kind, service, status, start/end
nanos, attributes, events, links) using an index-backed plan, optionally
bounded by a time window derived from the caller, and ordered by span start
time by default for waterfall construction.

#### Scenario: All spans of a trace returned

- **GIVEN** a trace with 12 spans across 3 services
- **WHEN** a client sends `in:traces trace_id:"<hex>" sort:start_time_unix_nano:asc`
- **THEN** all 12 span rows SHALL be returned in start-time order

#### Scenario: Span lookup is index-backed

- **WHEN** `EXPLAIN` runs the generated SQL for a `trace_id` equality filter
- **THEN** the plan SHALL use the `trace_id` index rather than a full
  hypertable scan

### Requirement: Rollup stats drill-down filters

Rollup stats queries for traces and metrics SHALL accept the filters needed by
clickable stat cards — at minimum `service_name` and an error predicate — and
the corresponding list-entity queries SHALL support equivalent filters so a
card click can re-query the list with the same constraint.

#### Scenario: Error-only trace list query

- **WHEN** a client sends `in:otel_trace_summaries error_count:>0 time:last_24h`
- **THEN** only trace summaries containing errors SHALL be returned

#### Scenario: Rollup stats narrowed by service

- **WHEN** a client sends `in:otel_traces service_name:web rollup_stats:summary`
- **THEN** the returned aggregates SHALL cover only that service
