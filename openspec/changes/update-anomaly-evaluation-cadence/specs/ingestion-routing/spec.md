## ADDED Requirements

### Requirement: Canonical Metric Signal Contract
The system SHALL provide a canonical `serviceradar.metric.v1` metric contract that can represent scalar and multi-point metrics with resource identity, metric kind, temporality, unit, point attributes, and gateway-attested ingest identity.

#### Scenario: Version-2 metric envelope carries OTLP-grade identity
- **WHEN** a producer emits a version-2 `serviceradar.metric.v1` envelope
- **THEN** the envelope SHALL include `resource`, `name`, `kind`, `unit`, and non-empty `points`
- **AND** sum or histogram metrics SHALL include valid `temporality`

#### Scenario: Version-1 flat metric remains compatible
- **GIVEN** a legacy version-1 flat `serviceradar.metric.v1` envelope
- **WHEN** the metric consumer receives it during migration
- **THEN** the consumer SHALL map it to a single gauge point
- **AND** it SHALL preserve the original metric name, value, unit, tags, and observed time where present

### Requirement: First-Class Metric Path
Metric producers SHALL emit metrics directly onto the metric ingestion path rather than embedding metric time-series inside status, check-result, or plugin-result envelopes.

#### Scenario: Status metric smuggling is replaced
- **GIVEN** a first-party collector such as sysmon, SNMP, ICMP, MTR, sweep, or rperf produces metric samples
- **WHEN** the samples are sent through the agent/gateway path
- **THEN** the gateway SHALL publish canonical metric envelopes to JetStream
- **AND** it SHALL NOT require source-specific JSON re-extraction from `GatewayServiceStatus.Message`

#### Scenario: Metrics stay out of OCSF
- **WHEN** a raw metric time-series payload is ingested
- **THEN** it SHALL be routed as a metric signal
- **AND** it SHALL NOT be persisted as an OCSF event
- **AND** OCSF SHALL remain valid for findings or events derived from metrics

### Requirement: Metric Stream Idempotency
The metric ingestion path SHALL provide idempotency for at-least-once delivery before enabling multi-point fan-out.

#### Scenario: Duplicate metric publish is suppressed
- **WHEN** a gateway publishes a canonical metric envelope to JetStream
- **THEN** it SHALL set `Nats-Msg-Id` from the gateway-stamped `ingress_id`
- **AND** the metrics stream SHALL have a duplicate window configured to suppress duplicate delivery within the window

### Requirement: Metric Schema Guardrails
Metric and OCSF processors SHALL reject misrouted payloads rather than silently coercing them into the wrong storage model.

#### Scenario: Metric payload is misrouted to OCSF
- **WHEN** an OCSF processor receives a payload containing metric-only fields such as `kind`, `temporality`, or `points`
- **THEN** it SHALL reject the payload with a bounded validation error

#### Scenario: OCSF payload is misrouted to metrics
- **WHEN** a metric processor receives a canonical metric payload containing OCSF event fields such as `class_uid`
- **THEN** it SHALL reject the payload with a bounded validation error
