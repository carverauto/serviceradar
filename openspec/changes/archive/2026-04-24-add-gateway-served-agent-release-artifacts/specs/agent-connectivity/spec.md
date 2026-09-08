## ADDED Requirements

### Requirement: Agents fetch rollout artifacts through agent-gateway
Agents SHALL fetch rollout artifact payloads through `agent-gateway` rather than requiring direct connectivity to external repository hosts. The rollout command SHALL carry a gateway-servable artifact reference or URL for the selected artifact.

#### Scenario: Agent downloads a mirrored release from gateway
- **GIVEN** an active rollout target references a mirrored artifact for version `v1.2.3`
- **WHEN** the gateway dispatches the release command to the connected agent
- **THEN** the command payload includes the gateway-served artifact reference or download URL
- **AND** the agent downloads the artifact from `agent-gateway`

#### Scenario: Agent remains blocked from unauthorized artifact access
- **GIVEN** an agent attempts to fetch a release artifact that is not associated with one of its authorized rollout targets
- **WHEN** the request reaches `agent-gateway`
- **THEN** the gateway rejects the request
- **AND** the agent does not receive the artifact payload
