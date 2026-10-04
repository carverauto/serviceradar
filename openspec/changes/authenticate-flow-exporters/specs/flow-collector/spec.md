## ADDED Requirements

### Requirement: Authenticated and authorized IPFIX ingress
The collector SHALL support native IPFIX over mutually authenticated TLS/TCP and
SHALL verify both the client certificate chain and an explicitly approved
exporter identity before creating or invoking flow parser state.

#### Scenario: Unapproved or unauthenticated peer
- **WHEN** a peer has no valid client certificate or its certificate identity is
  absent from the operator-approved exporter mapping
- **THEN** the collector SHALL reject the session before template, pending-record
  or sampling state is created or mutated
- **AND** it SHALL NOT publish that peer's flow records

#### Scenario: Approved exporter
- **WHEN** an approved exporter establishes mutual TLS and sends complete native
  IPFIX messages within configured bounds
- **THEN** the collector SHALL decode its templates and flow records and publish
  converted telemetry through the existing NATS JetStream pipeline

### Requirement: Transport-session template isolation
The collector SHALL isolate all IPFIX template, options, pending-record and
sampling state by authenticated transport session and observation domain, and
SHALL discard it when the session ends without restoring another session's state.

#### Scenario: Colliding exporter-declared fields
- **WHEN** two sessions declare identical addresses, domains and template IDs
- **THEN** one session's definitions and withdrawals SHALL NOT alter the other's
  state or decoding

#### Scenario: Reconnect or restart
- **WHEN** an authenticated exporter establishes a new transport session
- **THEN** the collector SHALL require templates in that session before decoding
  template-based records
- **AND** it SHALL NOT restore legacy UDP KV templates or prior-session templates

### Requirement: Explicit insecure UDP compatibility
The collector SHALL reject NetFlow v9 and IPFIX UDP datagrams before parser
admission unless `allow_unauthenticated_templates` is explicitly enabled, and
SHALL never attach shared template KV to an insecure UDP handler.

#### Scenario: Secure defaults
- **WHEN** a template-based UDP datagram arrives without the compatibility opt-in
- **THEN** it SHALL NOT create, replace, withdraw or restore any parser state
- **AND** template-free NetFlow v5 and sFlow ingestion SHALL remain available

#### Scenario: Operator accepts insecure legacy UDP
- **WHEN** the operator explicitly enables unauthenticated template ingestion
- **THEN** its state SHALL remain listener-local and separate from TLS sessions
- **AND** documentation SHALL identify source spoofing as an accepted remaining
  risk, not claim that source IP filtering authenticates an exporter

### Requirement: Bounded authenticated ingress
The collector SHALL bound concurrent sessions, sessions per approved exporter,
handshake/read time and IPFIX message size before allocating or parsing payloads.

#### Scenario: Invalid stream framing or exhausted capacity
- **WHEN** a session exceeds its limits or sends invalid, partial or oversized
  native IPFIX frames
- **THEN** the collector SHALL reject or terminate it without plaintext fallback
- **AND** other admitted exporters and the NATS publisher SHALL continue operating
