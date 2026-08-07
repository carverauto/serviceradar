## MODIFIED Requirements

### Requirement: Required Local OTLP Terminator on Every Agent

Every agent SHALL include a local OTLP terminator (`otel-collector`) as a
required, auto-installed component. The default terminator transport SHALL be
the durable gateway relay, which requires no edge NATS access or NATS
credential on the base agent. The terminator MAY use direct JetStream output
only when an operator explicitly enables it for a registered site-local NATS
leaf.

#### Scenario: Default OTLP relay without a NATS leaf

- **WHEN** OTLP is emitted at an edge site without a registered local NATS
  leaf
- **THEN** the terminator durably spools the accepted telemetry
- **AND** relays it through the agent and agent-gateway
- **AND** the agent does not require a NATS credential

#### Scenario: Direct OTLP output with a local leaf

- **GIVEN** a site-local NATS leaf is deployed and registered
- **AND** an operator explicitly selects direct JetStream output
- **WHEN** the terminator is configured
- **THEN** it publishes only to the registered local leaf using leaf-scoped
  authentication
- **AND** the direct authentication is delivered on demand to the add-on
- **AND** no central platform NATS credential is placed in the base agent
  bundle

#### Scenario: Direct output is disabled or revoked

- **GIVEN** an agent add-on was previously configured for direct leaf output
- **WHEN** the operator disables the direct mode or unregisters the leaf
- **THEN** the add-on falls back to gateway relay or enters an explicit
  degraded state according to policy
- **AND** the leaf-scoped authentication is revoked or removed

