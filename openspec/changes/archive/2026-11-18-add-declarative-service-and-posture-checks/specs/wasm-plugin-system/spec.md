## ADDED Requirements

### Requirement: Shipped First-Party Declarative Check Runner Wasm Plugin
The system SHALL ship and sign (`UploadSignature`) one first-party generic WASI plugin (`io.serviceradar.declarative-check-runner`) for `serviceradar-agent`, and `DeclarativeCheckAssignmentCompiler` SHALL compile Edge-only and Hybrid Edge declarative check subgraphs (`http_request`, `http_journey`, `tcp_connect`, `tls_handshake`, `dns_lookup`, plus pure `extract_field`, `threshold_assert`, `decision_table`, and `alert_output` nodes) into standard agent plugin assignments targeting that single runner without generating per-check Wasm binaries.

#### Scenario: Edge declarative check compiles into a declarative-check-runner assignment
- **GIVEN** an enabled declarative check containing `tls_handshake` (`leaf_days_remaining`) and `http_request` nodes assigned to an agent
- **WHEN** `DeclarativeCheckAssignmentCompiler` materializes agent configuration
- **THEN** the agent config SHALL include a `declarative-check-runner` plugin assignment carrying the validated secret-free Edge subgraph, target batch, schedule, and strict host/port allowlists
- **AND** no bespoke Wasm compilation SHALL occur at check authoring time

### Requirement: Declarative Check Runner Host Credential Injection, Httptrace Waterfalls, and Durable Spooling
The `declarative-check-runner` Wasm plugin on `serviceradar-agent` MUST inject credentials exclusively via `SecretBroker` (`CredentialBrokerGrant`) host capabilities enforced against domain/IP/port allowlists, MUST capture `httptrace` phase timings (`dns_ms`, `tcp_ms`, `tls_ms`, `ttfb_ms`, `transfer_ms`, `total_ms`) for `http_request` and `http_journey` steps, and MUST persist results and step telemetry through the agent's durable `RecordSpool` for delivery to NATS JetStream.

#### Scenario: Multi-step synthetic HTTP journey records httptrace waterfall and buffers through RecordSpool
- **GIVEN** an `http_journey` declarative check referencing an abstract `credential_slot` resolved via a `CredentialBrokerGrant` for `https://api.example.com`
- **WHEN** `serviceradar-agent` executes `declarative-check-runner` while NATS connectivity is temporarily unavailable
- **THEN** the host runtime SHALL inject the brokered credential header only for allowlisted `api.example.com:443` requests, record per-step `httptrace` phase timings without logging or returning secret bytes, and spool the `serviceradar.plugin_result.v1` and step records in `RecordSpool` until NATS JetStream delivery succeeds

#### Scenario: Disallowed redirect or host is blocked during declarative check execution
- **GIVEN** an `http_journey` check allowlisted for `https://status.example.com`
- **WHEN** a response redirects to `http://192.0.2.99/internal` outside the assignment allowlist
- **THEN** the agent host capability check SHALL deny the outbound request and strip brokered credentials, recording a bounded allowlist error on the step
