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
Access to `in:otel_services` SHALL be enforced in two places. The shared `EntityAccess` gate used by the LiveView, HTTP and MCP query paths SHALL map this entity to an any-of permission set (`observability.logs.view`, `observability.traces.view`, `observability.metrics.view`), SHALL reject a caller holding none, and SHALL pass the caller's permitted signal set to SRQL as a trusted parameter that is separate from the query string and is not part of the wire-deserialized request. Every caller of the gate, and every translate call site including re-translation, SHALL pass that set. The standalone SRQL server has no trusted-caller path and SHALL reject `otel_services` queries. Other entities SHALL keep single-permission gating.

The SRQL planner for `otel_services` SHALL be the single parser of `signal:`. It SHALL intersect the parsed `signal:` values with the permitted set, and with no `signal:` it SHALL use the permitted set. It SHALL fail closed with one error contract. A permission failure (a named or list-form `signal:` value outside the set, an empty intersection, or a missing permitted set) SHALL return a distinct forbidden error kind, which web-ng maps to `{:error, :forbidden}` and HTTP 403. A malformed form (a repeated `signal:` token or a negated `signal:`) SHALL return an invalid-request error (HTTP 400).

The `otel_services` mapping MUST be enforced before the SRQL entity is reachable, because the gate treats unmapped entities as authorized.

#### Scenario: Signal the caller cannot view
- **GIVEN** a caller with `observability.logs.view` but not `observability.traces.view`
- **WHEN** the caller sends `in:otel_services signal:traces`
- **THEN** the query SHALL be rejected as forbidden

#### Scenario: Unscoped query is narrowed to permitted signals
- **GIVEN** a caller with only `observability.logs.view`
- **WHEN** the caller sends `in:otel_services`
- **THEN** only services that have reported logs SHALL be returned
- **AND** the `signals` field SHALL NOT disclose traces or metrics

#### Scenario: List form is intersected with the permitted set
- **GIVEN** a caller with only `observability.logs.view`
- **WHEN** the caller sends `in:otel_services signal:(logs,traces)`
- **THEN** the query SHALL be rejected as forbidden

#### Scenario: Repeated or negated signal token
- **GIVEN** a caller with only `observability.logs.view`
- **WHEN** the caller sends `in:otel_services signal:logs signal:traces`, or `in:otel_services !signal:logs`
- **THEN** each query SHALL be rejected as an invalid request

#### Scenario: Differently cased key
- **GIVEN** a caller with only `observability.logs.view`
- **WHEN** the caller sends `in:otel_services SIGNAL:traces`
- **THEN** the query SHALL be rejected as forbidden, the same as `signal:traces`

#### Scenario: Missing permitted set fails closed
- **WHEN** SRQL receives `in:otel_services` with no permitted signal set
- **THEN** the query SHALL be rejected as forbidden and no catalog rows SHALL be returned

#### Scenario: Client cannot supply the permitted set
- **WHEN** a client sends a request body to the standalone SRQL server containing `in:otel_services` and a permitted-signals field
- **THEN** the field SHALL be ignored and the query SHALL be rejected as forbidden

#### Scenario: Re-translation keeps the permitted set
- **GIVEN** a caller with only `observability.logs.view`
- **WHEN** a query is re-translated after a rollup freshness settle
- **THEN** the re-translated query SHALL still be restricted to the permitted signals

#### Scenario: Caller with no observability permission
- **GIVEN** a caller with none of the three observability view permissions
- **WHEN** the caller sends `in:otel_services`
- **THEN** the query SHALL be rejected as forbidden

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

#### Scenario: Negation includes traces with no services
- **GIVEN** a trace whose `service_set` is NULL
- **WHEN** a client sends `in:otel_trace_summaries !service_name:checkout`
- **THEN** that trace SHALL be returned

#### Scenario: Wildcard rejected
- **WHEN** a client sends `in:otel_trace_summaries service_name:%check%`
- **THEN** SRQL SHALL return an invalid-request error naming the field
