## ADDED Requirements

### Requirement: Elixir OTLP export uses canonical identifier encoding

The Elixir services' OTLP exports (spans and logs) SHALL place raw binary
identifiers in OTLP `trace_id`/`span_id` bytes fields — never ASCII hex text —
so downstream consumers' single hex-encoding step produces canonical 32/16
character lowercase hex. The OTLP log export bridge SHALL attach the active
span context to exported log records so Elixir-emitted logs are joinable to
their traces.

#### Scenario: Exported log record carries binary ids

- **GIVEN** an Elixir process logging inside an active span
- **WHEN** the log record is exported over OTLP
- **THEN** the `LogRecord.trace_id` field SHALL contain the 16 raw bytes of the
  span context trace id (not the 32-byte ASCII hex string)
- **AND** the stored `logs.trace_id` SHALL equal the stored
  `otel_traces.trace_id` for that span

#### Scenario: Logs outside spans carry no ids

- **WHEN** a log record is exported from a process with no active span
- **THEN** the exported `trace_id`/`span_id` SHALL be empty and stored as NULL

### Requirement: Cross-service and async trace propagation

Elixir services SHALL propagate W3C trace context on outbound gRPC/HTTP calls
and SHALL inject/extract context on NATS messages used for internal async
hops, so multi-service operations produce connected traces rather than
per-service single-span roots.

#### Scenario: NATS hop preserves the trace

- **GIVEN** core-elx publishes a NATS message while inside a span
- **WHEN** a consumer service processes the message and starts a span
- **THEN** the consumer span SHALL share the publisher's `trace_id` and
  reference its `span_id` as parent

#### Scenario: Span status recorded on failure

- **WHEN** an instrumented operation fails
- **THEN** the emitted span SHALL carry OTLP status ERROR (status_code=2) so
  error-rate rollups reflect real failures
