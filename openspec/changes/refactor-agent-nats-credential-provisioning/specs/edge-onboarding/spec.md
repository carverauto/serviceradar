## ADDED Requirements

### Requirement: Base agent onboarding is independent of NATS credentials

The base agent onboarding lifecycle SHALL succeed without a configured NATS
account name, NATS account seed, per-agent NATS credential, or central NATS
endpoint. A missing legacy `nats_credential_id` SHALL NOT prevent package
delivery or agent enrollment unless the operator explicitly selected a
direct-to-leaf capability.

#### Scenario: Default agent package without NATS account configuration

- **GIVEN** an operator creates an ordinary agent onboarding package
- **AND** the control plane has no NATS account seed configured for agent
  packages
- **WHEN** the package is created and delivered
- **THEN** package creation succeeds
- **AND** delivery succeeds
- **AND** the bundle contains the gateway/mTLS enrollment material
- **AND** the bundle contains no `nats.creds`, `nats_creds_file`, or central
  `nats_url`

#### Scenario: Agent enrolls without edge NATS

- **GIVEN** an agent receives a default base onboarding bundle
- **AND** no NATS leaf is deployed at the site
- **WHEN** the agent starts
- **THEN** it enrolls over its existing outbound mTLS gateway connection
- **AND** it remains operational without an edge NATS credential

### Requirement: Direct-to-leaf NATS access is explicit

The platform SHALL provision direct NATS authentication for an agent add-on
only after an operator explicitly selects direct-to-leaf mode and the target
site-local NATS leaf is registered and eligible. The add-on assignment SHALL
record the selected edge site; a URL embedded only in add-on parameters is not
an authoritative leaf association. Direct-leaf material SHALL not be included
in the base onboarding package.

#### Scenario: Direct mode requires a registered leaf

- **GIVEN** an operator requests direct JetStream output for an edge add-on
- **AND** no eligible site-local NATS leaf is registered
- **WHEN** the control plane evaluates the request
- **THEN** it leaves the direct assignment pending or reports an actionable
  configuration error
- **AND** it does not mint or deliver a central platform NATS credential

#### Scenario: Direct mode uses the registered leaf endpoint

- **GIVEN** an operator enables direct JetStream for an add-on assignment
- **AND** the assignment selects an active edge site with a connected NATS leaf
- **WHEN** the control plane evaluates the add-on configuration
- **THEN** the configured NATS endpoint matches the registered edge-site leaf URL
- **AND** an arbitrary central or unregistered endpoint is not delivered

#### Scenario: Direct mode requires assignment-scoped leaf mTLS

- **GIVEN** an operator enables direct JetStream for an edge add-on
- **WHEN** the control plane has not issued and delivered the assignment-scoped
  leaf mTLS identity
- **THEN** the direct assignment remains pending or degraded
- **AND** a NATS `.creds` file is not minted or delivered by this capability

#### Scenario: Direct mode records a bounded subject scope

- **GIVEN** an operator enables direct JetStream output for an add-on
- **WHEN** the assignment is saved
- **THEN** the control plane records the exact OTEL publish subjects, the
  selected JetStream stream, and the request/ack subscription subjects
- **AND** it does not derive a broad `events.>` or other platform-wide scope
- **AND** the assignment remains pending until the exact leaf ACL is applied
  and a system-only readiness action marks that scope and generation ready

#### Scenario: Direct identity readiness is revoked on assignment changes

- **GIVEN** a direct assignment has a ready leaf identity
- **WHEN** its selected site or subject contract changes
- **THEN** the direct identity generation advances
- **AND** the assignment returns to pending
- **AND** the previous identity is not delivered for the new scope

#### Scenario: Direct mode provisions scoped material on demand

- **GIVEN** an eligible site-local NATS leaf is registered
- **AND** an operator explicitly enables direct output for one add-on
- **WHEN** the add-on configuration is delivered
- **THEN** only the selected add-on receives the leaf-scoped authentication
- **AND** the base agent bundle remains free of NATS credentials
- **AND** the authentication cannot publish or subscribe outside its declared
  leaf/add-on subject scope
- **AND** the selected leaf has a matching certificate-CN authorization block
  for the same scope
