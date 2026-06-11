## ADDED Requirements

### Requirement: Transport-agnostic trace context carrier API

The SDK SHALL expose a carrier-based W3C trace-context API — inject the
active span context into a string-keyed header map, and extract a remote
parent context from one — independent of any specific transport, so new
messaging adapters (Kafka, MQTT, etc.) can be added without changing the
public API. Injection with no active span SHALL be a no-op; extraction of
absent or malformed headers SHALL yield no parent rather than an error.

#### Scenario: Inject then extract round-trips

- **GIVEN** an application with an active span using the SDK
- **WHEN** it injects into a header map and a consumer extracts from it
- **THEN** the consumer's new span SHALL share the producer's trace_id and
  reference the producer's span_id as parent

#### Scenario: Malformed headers degrade gracefully

- **WHEN** extraction runs against headers with a corrupt traceparent
- **THEN** no error SHALL be raised and the consumer span SHALL start a new
  trace

### Requirement: NATS adapter with messaging semantics

The SDK SHALL provide a NATS adapter that injects context on publish and
extracts on message handling, plus optional producer/consumer span helpers
that set messaging semconv attributes (messaging.system="nats", destination
subject, operation) and mark span status on failures.

#### Scenario: NATS publish-subscribe stays one trace

- **GIVEN** a producer and consumer both using the SDK's NATS adapter
- **WHEN** a message flows producer → NATS → consumer
- **THEN** the consumer span SHALL be a child in the producer's trace with
  messaging.* attributes populated on both sides

### Requirement: Multi-language parity

The SDK SHALL ship for Go, Rust, and Elixir initially with semantically
identical behavior (same header keys, same no-op/graceful-degradation
rules), validated by a shared cross-language conformance fixture (inject in
language A, extract in language B).

#### Scenario: Cross-language hop

- **WHEN** a Go producer injects and an Elixir consumer extracts (or any
  pairing)
- **THEN** trace continuity SHALL hold exactly as in the single-language
  case

### Requirement: ServiceRadar-ready defaults

The SDK SHALL include examples and helper configuration preconfigured for
ServiceRadar ingestion — the central collector endpoints (gRPC 4317 /
HTTP 4318) and the edge collector add-on's local endpoint convention — so a
user goes from "SDK added" to "correlated traces visible in ServiceRadar"
without reverse-engineering transport details.

#### Scenario: Example app produces correlated telemetry

- **WHEN** a user runs a shipped example against a reachable ServiceRadar
  collector
- **THEN** its NATS producer/consumer trace SHALL appear in the trace
  detail view as one multi-span trace

### Requirement: Platform dogfooding

ServiceRadar's own components SHALL migrate to the SDK for messaging trace
propagation (replacing bespoke glue) so the SDK is continuously exercised
by the platform itself; the rust add-on SDK SHALL re-export the Rust
package for add-on authors.

#### Scenario: Core uses the SDK

- **WHEN** core-elx publishes an internal NATS message inside a span
- **THEN** the injected headers SHALL come from the SDK package, not
  platform-private code
