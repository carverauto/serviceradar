## MODIFIED Requirements

### Requirement: Minimal bootstrap configuration

The on-disk agent bootstrap configuration MUST include the SaaS/gateway
endpoint and mTLS credentials, plus optional agent identity overrides. It MAY
include an explicitly selected local transport capability, but the default
bootstrap configuration MUST NOT include a central NATS endpoint, a platform
NATS credential, or a per-agent NATS account seed. Monitoring roles, checks,
schedules, and optional add-on transport configuration MUST be delivered by
the versioned configuration path.

#### Scenario: Default bootstrap has no NATS material

- **GIVEN** an agent is onboarded for the normal gateway-relay deployment
- **WHEN** the bootstrap configuration is written
- **THEN** it contains the gateway endpoint and mTLS credentials
- **AND** it contains no central `nats_url` or `nats_creds_file`
- **AND** the agent can start without a NATS credential

#### Scenario: Explicit local leaf configuration is delivered separately

- **GIVEN** an operator has enabled direct output for an add-on
- **AND** a site-local NATS leaf is registered for the agent's site
- **WHEN** the configuration update is delivered
- **THEN** the direct-leaf endpoint and add-on-scoped authentication are
  delivered through the explicit configuration lifecycle
- **AND** the base bootstrap configuration is not broadened with platform
  NATS authority

