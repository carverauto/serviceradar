## ADDED Requirements

### Requirement: Gateways serve mirrored agent release artifacts
The edge architecture SHALL allow `agent-gateway` to serve mirrored agent release artifacts from internal object storage to authorized edge agents over HTTPS.

#### Scenario: Gateway serves a mirrored artifact
- **GIVEN** the control plane has mirrored a rollout artifact into internal object storage
- **AND** an authorized agent has an active rollout target for that artifact
- **WHEN** the agent requests the artifact from `agent-gateway`
- **THEN** the gateway retrieves the object from internal storage and serves it over HTTPS
- **AND** the gateway does not need direct artifact bytes embedded in the control command stream

#### Scenario: Internal artifact storage supports repo-hosted source of truth
- **GIVEN** the operator uses GitHub, Forgejo, or Harbor as the source of truth for published releases
- **WHEN** a release is imported into ServiceRadar
- **THEN** the control plane mirrors the release artifacts into internal storage
- **AND** gateways serve the mirrored copy to agents even if the agents cannot reach the original repository host
