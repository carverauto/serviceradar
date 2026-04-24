## MODIFIED Requirements

### Requirement: Agents fetch rollout artifacts through agent-gateway
Agents SHALL fetch rollout artifact payloads through `agent-gateway` rather than requiring direct connectivity to external repository hosts. The rollout command SHALL carry a gateway-servable artifact reference or URL for the selected artifact. The gateway SHALL authorize each artifact request against the authenticated agent identity in addition to the rollout target metadata.

#### Scenario: Gateway rejects artifact request from the wrong authenticated agent
- **GIVEN** an active rollout target belongs to agent `agent-a`
- **AND** a different authenticated agent `agent-b` presents valid mTLS credentials to `agent-gateway`
- **WHEN** `agent-b` requests the artifact using `agent-a`'s target and command identifiers
- **THEN** the gateway rejects the request
- **AND** `agent-b` does not receive the artifact payload
