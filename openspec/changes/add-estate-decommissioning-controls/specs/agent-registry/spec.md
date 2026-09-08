# agent-registry Specification

## ADDED Requirements

### Requirement: Agent Decommissioning

An operator SHALL be able to decommission an agent from the agent detail view. The system
SHALL revoke the agent's mTLS identity at its issuing gateway so the agent cannot
re-establish a session, and SHALL retire the agent's registry row from active operational
views.

Decommissioning SHALL be authorized on every invocation, and SHALL be distinguishable in
the UI from deleting an onboarding package -- deleting a delivered package revokes nothing
and is not a decommission.

Retirement SHALL NOT delete the historical row. An agent that is decommissioned SHALL
remain queryable for audit, carrying who decommissioned it and when.

#### Scenario: Decommissioning stops an agent reconnecting
- **GIVEN** agent `agent-dusk01` is `Connected` via gateway `gateway-platform`
- **WHEN** an authorized operator decommissions it from the agent detail page
- **THEN** its certificate is revoked at that gateway
- **AND** the agent cannot establish a new session with the revoked identity
- **AND** its registry row is retired from active operational selectors
- **AND** the row remains readable for audit with the actor and timestamp recorded

#### Scenario: Deleting an onboarding package is not a decommission
- **GIVEN** an onboarding package for `agent-dusk01` whose status is `delivered`
- **WHEN** an operator deletes that package
- **THEN** the agent's certificate remains valid and the agent stays connected
- **AND** the interface SHALL NOT present package deletion as a way to remove the agent

#### Scenario: Decommissioning an agent that is already offline
- **GIVEN** an agent whose process has already stopped
- **WHEN** an operator decommissions it
- **THEN** revocation is still recorded so the identity cannot be reused if the host returns
- **AND** the operation reports success rather than failing on the absent session
