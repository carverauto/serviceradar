# Observability signals Specification Delta

## MODIFIED Requirements

### Requirement: Raw logs ingestion

The system SHALL ingest syslog, SNMP traps, GELF logs, and OTEL logs as OTEL
log records with source metadata and tenant scoping. OTEL fields (timestamp,
severity, body, resource, scope, attributes, and trace/span identifiers when
present) SHALL be preserved in storage and query results. Syslog ingestion in
the default collector configuration SHALL accept RFC3164, RFC5424, and the
supported ClearPass standard header without requiring a sender-specific
deployment. An unrecognized syslog format SHALL remain a lossless log record
with its receive timestamp and observed source metadata.

#### Scenario: SNMP trap stored as OTEL log

- **WHEN** an SNMP trap is received
- **THEN** the system SHALL persist the log as an OTEL log record
- **AND** it SHALL include source metadata and a normalized severity/body

#### Scenario: OTEL log attributes preserved

- **WHEN** an OTEL log record is ingested
- **THEN** the system SHALL retain resource attributes, scope attributes, and
  log attributes
- **AND** trace/span identifiers SHALL be queryable when present

#### Scenario: RFC3164 and RFC5424 syslog accepted by the default collector

- **WHEN** the default syslog collector receives valid RFC3164 or RFC5424
  input
- **THEN** it SHALL create one OTEL log record for the message
- **AND** it SHALL preserve the decoded timestamp, body, severity, and source
  metadata

#### Scenario: ClearPass standard syslog accepted

- **WHEN** the collector receives a ClearPass standard message with a
  comma-millisecond timestamp and a free-form or escaped multiline body
- **THEN** it SHALL create one OTEL log record
- **AND** it SHALL preserve the complete body without splitting the datagram

#### Scenario: Opaque vendor message remains searchable

- **WHEN** the collector receives a CEF, LEEF, or other syslog message that
  has no dedicated semantic decoder
- **THEN** it SHALL store the complete original message as the log body
- **AND** it SHALL identify the record as an unknown or opaque syslog format

### Requirement: OTEL log schema visibility in the UI

The Logs UI SHALL surface OTEL log fields in the detail view, including
resource attributes, scope information, attributes, trace/span identifiers,
and the collector-observed source IP when present.

#### Scenario: Log detail shows OTEL metadata

- **GIVEN** a user opens a log detail view
- **WHEN** the log record includes OTEL resource/scope/attributes
- **THEN** the UI SHALL display those OTEL fields alongside time, severity,
  service, and body

#### Scenario: Log detail shows source IP

- **GIVEN** a syslog record includes a valid observed source IP
- **WHEN** a user opens the log detail view
- **THEN** the UI SHALL display the value as Source IP independently of the
  message body
- **AND** the value SHALL be queryable through the log API/query contract

## ADDED Requirements

### Requirement: Automatic syslog format detection

The syslog collector SHALL support an `auto` input mode that attempts RFC5424,
RFC3164, and the supported ClearPass standard decoder in a deterministic order.
Explicit decoder modes SHALL remain available for strict deployments.

#### Scenario: RFC5424 is selected before legacy decoders

- **WHEN** auto mode receives a valid RFC5424 message with version `1` and an
  RFC3339 timestamp
- **THEN** it SHALL decode the message as RFC5424
- **AND** it SHALL preserve structured data and the remaining message body

#### Scenario: Explicit strict mode remains available

- **GIVEN** a deployment explicitly configures `rfc3164` or `rfc5424`
- **WHEN** the collector receives input
- **THEN** it SHALL use the configured decoder
- **AND** changing the default to auto SHALL not silently override that value

### Requirement: Syslog source peer provenance

The system SHALL preserve the source IP observed by the syslog collector as a
first-class optional log field named `source_ip`. Partition-qualified transport
metadata SHALL be normalized without losing the original compatibility
attribute, and invalid or absent addresses SHALL not prevent log ingestion.

#### Scenario: Qualified peer address becomes source IP

- **GIVEN** the collector emits `_remote_addr` as `default:10.208.254.4`
- **WHEN** EventWriter persists the log
- **THEN** `source_ip` SHALL be `10.208.254.4`
- **AND** the raw `_remote_addr` value SHALL remain available for compatibility

#### Scenario: IPv6 peer address is preserved

- **GIVEN** the collector emits an IPv6 peer address with or without a
  partition prefix
- **WHEN** EventWriter normalizes the record
- **THEN** it SHALL preserve the complete IPv6 address in `source_ip`
- **AND** it SHALL not split the address at its internal colons

#### Scenario: Missing peer address does not drop a log

- **WHEN** a log arrives without a valid `_remote_addr`
- **THEN** the system SHALL persist the log with `source_ip` set to null
- **AND** the remaining log body and attributes SHALL be retained

### Requirement: Lossless syslog parse fallback

Auto-mode syslog ingestion SHALL create a normal log record when no supported
decoder can parse the message. The fallback SHALL retain the original body,
the collector receive timestamp, and any observed source IP, and SHALL emit
bounded diagnostics that identify the parse fallback.

#### Scenario: Malformed message is retained

- **WHEN** auto mode receives a malformed or unsupported syslog message
- **THEN** it SHALL persist the complete original message as the body
- **AND** it SHALL mark the record as an unknown or fallback syslog format
- **AND** it SHALL not discard the datagram solely because parsing failed

#### Scenario: Fallback diagnostics are bounded

- **WHEN** a sender repeatedly emits an unsupported format
- **THEN** the collector SHALL expose a counter or sampled diagnostic for
  fallback parsing
- **AND** it SHALL avoid emitting an unbounded per-message error stream
