## ADDED Requirements

### Requirement: OTel services catalog entity
SRQL SHALL expose the OTel service catalog as `in:otel_services`, returning `service_name`, `signals`, `last_seen`, `logs_last_seen`, `traces_last_seen` and `metrics_last_seen`.

- **Filters.** The entity SHALL support filtering `service_name` (exact, list, negated, and `%` wildcards compiled to case-insensitive `ILIKE`) and `signal:` (`logs`, `traces`, `metrics`, or a list meaning any of them).
- **Time.** `time:` SHALL apply to the last-seen of the requested signals, or of the caller's permitted signals when no signal is given.
- **Derived fields.** `signals`, `last_seen` and the default `last_seen:desc` ordering SHALL derive only from the requested signals, or from the caller's permitted signals when no signal is given. Per-signal last-seen fields for any other signal SHALL be null.
- **Sort.** Sorting SHALL be supported on `service_name` and `last_seen`, with `last_seen:desc` as the default.
- **Limit.** The default limit SHALL be 50 and the maximum 500.
- **Stats.** `stats:"count() as total"` SHALL be supported.
- **Backend.** The entity SHALL always read CNPG, regardless of StarRocks cutover.

This entity is distinct from `in:services`, which reads monitored service checks.

#### Scenario: Substring search with a bounded result
- **WHEN** a client sends `in:otel_services signal:logs service_name:%pay% limit:50`
- **THEN** at most 50 catalog entries whose name contains `pay` (case-insensitive) and that have reported logs SHALL be returned, ordered by most recently seen

#### Scenario: Match count for a search
- **WHEN** a client sends `in:otel_services signal:traces service_name:%pay% stats:"count() as total"`
- **THEN** the response SHALL contain the total number of matching entries

#### Scenario: Limit above the maximum
- **WHEN** a client sends `in:otel_services limit:5000`
- **THEN** at most 500 rows SHALL be returned

#### Scenario: Not confused with monitored services
- **WHEN** a client sends `in:services`
- **THEN** SRQL SHALL continue to return monitored service check status, not catalog entries

### Requirement: OTel services entity access control
Access to `in:otel_services` SHALL be enforced by the shared `EntityAccess` gate used by the LiveView, HTTP and MCP query paths. The gate SHALL support an any-of permission mapping for this entity and SHALL rewrite a query that has no `signal:` so that it is restricted to the signals the caller may view. A named signal SHALL still require that signal's view permission (`observability.logs.view`, `observability.traces.view` or `observability.metrics.view`). A query without `signal:` SHALL require at least one of them and SHALL be rejected when the caller holds none. Other entities SHALL keep single-permission gating.

The `otel_services` mapping MUST be enforced before the SRQL entity is reachable, because the gate treats unmapped entities as authorized.

#### Scenario: Signal the caller cannot view
- **GIVEN** a caller with `observability.logs.view` but not `observability.traces.view`
- **WHEN** the caller sends `in:otel_services signal:traces`
- **THEN** the query SHALL be rejected as unauthorized

#### Scenario: Unscoped query is narrowed to permitted signals
- **GIVEN** a caller with only `observability.logs.view`
- **WHEN** the caller sends `in:otel_services`
- **THEN** only services that have reported logs SHALL be returned
- **AND** the `signals` field SHALL NOT disclose traces or metrics

#### Scenario: Caller with no observability permission
- **GIVEN** a caller with none of the three observability view permissions
- **WHEN** the caller sends `in:otel_services`
- **THEN** the query SHALL be rejected as unauthorized

#### Scenario: Narrowed query does not leak other-signal activity
- **GIVEN** `checkout` reported logs an hour ago and traces one minute ago
- **AND** a caller with only `observability.logs.view`
- **WHEN** the caller sends `in:otel_services time:last_2h`
- **THEN** `last_seen` SHALL reflect the logs activity only
- **AND** `traces_last_seen` SHALL be null
- **AND** the default `last_seen:desc` ordering and the `time:` filter SHALL ignore the trace activity

### Requirement: Trace summaries filter by participating service
`in:otel_trace_summaries` SHALL accept a `service_name` filter that matches a trace when any of its spans belongs to the given service (containment in `service_set`). The list form SHALL match traces touching any listed service, and negation SHALL exclude traces touching the service.

The existing `root_service_name` filter SHALL keep its root-span-only meaning. Wildcard values for `service_name` on this entity SHALL be rejected with an invalid-request error.

#### Scenario: Trace touching a service below the root
- **GIVEN** a trace whose root span is in `frontend` and which contains a span in `checkout`
- **WHEN** a client sends `in:otel_trace_summaries service_name:checkout time:last_24h`
- **THEN** that trace SHALL be returned

#### Scenario: Root-only filter unchanged
- **GIVEN** the same trace
- **WHEN** a client sends `in:otel_trace_summaries root_service_name:checkout time:last_24h`
- **THEN** that trace SHALL NOT be returned

#### Scenario: Multiple services
- **WHEN** a client sends `in:otel_trace_summaries service_name:(checkout,billing)`
- **THEN** traces touching either service SHALL be returned

#### Scenario: Wildcard rejected
- **WHEN** a client sends `in:otel_trace_summaries service_name:%check%`
- **THEN** SRQL SHALL return an invalid-request error naming the field
