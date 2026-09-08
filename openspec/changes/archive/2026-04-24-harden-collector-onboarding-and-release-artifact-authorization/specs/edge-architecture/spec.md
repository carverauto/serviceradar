## MODIFIED Requirements

### Requirement: Gateways serve mirrored agent release artifacts
The edge architecture SHALL allow `agent-gateway` to serve mirrored agent release artifacts from internal object storage to authorized edge agents over HTTPS. Artifact authorization SHALL be bound to the authenticated workload identity presented over mTLS, not only to request headers.

#### Scenario: Gateway serves artifact only to the intended authenticated agent
- **GIVEN** the control plane has mirrored a rollout artifact into internal object storage
- **AND** an authorized rollout target is associated with agent `agent-a`
- **WHEN** `agent-a` requests the artifact from `agent-gateway` using its active target metadata over mTLS
- **THEN** the gateway retrieves the object from internal storage and serves it over HTTPS
- **AND** the gateway confirms the authenticated caller identity matches the intended rollout target before serving bytes
