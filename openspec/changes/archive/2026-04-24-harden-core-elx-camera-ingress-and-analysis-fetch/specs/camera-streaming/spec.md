## MODIFIED Requirements
### Requirement: Analysis branches may dispatch to external HTTP workers

The system SHALL allow a relay-scoped analysis branch to dispatch bounded `camera_analysis_input.v1` payloads to configured external HTTP workers without creating another upstream camera pull.

#### Scenario: Relay sample is delivered to a worker
- **GIVEN** an active relay session with an attached analysis branch
- **AND** an HTTP worker is configured for that branch
- **WHEN** the branch emits a bounded analysis input
- **THEN** the platform SHALL dispatch the normalized input payload to the worker
- **AND** SHALL keep the dispatch associated with the originating relay session and branch identity

#### Scenario: Analysis worker dispatch rejects unsafe endpoints
- **GIVEN** an analysis worker endpoint resolves to a loopback, link-local, private, or otherwise disallowed target
- **WHEN** core-elx attempts to dispatch analysis input or probe worker health
- **THEN** the request SHALL be rejected before any HTTP connection is made
- **AND** the worker SHALL NOT be contacted through a redirect or rebinding path

#### Scenario: Analysis worker dispatch is bound to the validated target
- **GIVEN** an analysis worker endpoint resolves to an allowed public address
- **WHEN** core-elx dispatches analysis input or probes worker health
- **THEN** the HTTP client SHALL connect to the validated resolved address
- **AND** SHALL preserve the original hostname only for request/TLS host validation semantics
