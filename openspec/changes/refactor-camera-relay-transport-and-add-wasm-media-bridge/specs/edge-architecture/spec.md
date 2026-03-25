## ADDED Requirements
### Requirement: Camera media uses gRPC at the edge and ERTS inside the platform
Live camera media transport SHALL use the dedicated camera media gRPC service only on the edge-facing `agent -> serviceradar-agent-gateway` hop. After `serviceradar-agent-gateway` terminates edge gRPC and authenticates the session, platform-internal camera media forwarding to `serviceradar_core_elx` SHALL use ERTS-native messaging.

#### Scenario: Gateway forwards media to core without an internal gRPC hop
- **GIVEN** an authenticated agent uploads camera media to `serviceradar-agent-gateway`
- **WHEN** the gateway forwards that session into the platform
- **THEN** the gateway SHALL use an ERTS-native ingress boundary in `serviceradar_core_elx`
- **AND** the gateway SHALL NOT open a second gRPC media channel to `serviceradar_core_elx`

### Requirement: Camera relay ingress is session-scoped inside the platform
The platform SHALL allocate a session-scoped ingress target for each live camera relay so high-rate media chunks can be forwarded without per-chunk distributed RPC negotiation.

#### Scenario: Gateway reuses an ingress target for a relay session
- **GIVEN** `serviceradar-agent-gateway` has opened a camera relay session with `serviceradar_core_elx`
- **WHEN** subsequent media chunks or heartbeats arrive for that relay session
- **THEN** the gateway SHALL reuse the previously allocated ingress target for the session
- **AND** per-chunk routing SHALL NOT require fresh service discovery or a new gRPC connection
