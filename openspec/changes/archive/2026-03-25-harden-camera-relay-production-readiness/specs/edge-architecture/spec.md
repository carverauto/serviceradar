## ADDED Requirements
### Requirement: Camera media uploads complete with explicit terminal acknowledgment
Camera media uploads over the dedicated relay gRPC service SHALL explicitly terminate the request stream before the sender treats the upload as successful. A sender SHALL wait for the terminal acknowledgment from the next hop before considering the upload accepted.

#### Scenario: Gateway forwards a media upload batch to core-elx
- **GIVEN** the gateway is streaming one or more camera media chunks to the upstream relay ingress
- **WHEN** the current upload batch is complete
- **THEN** the gateway SHALL half-close the request stream
- **AND** SHALL wait for the upstream upload acknowledgment
- **AND** SHALL NOT report upload success to the sender until that acknowledgment is received

### Requirement: Gateway relay lease state mirrors upstream relay decisions
The gateway camera relay session state SHALL preserve the upstream relay lease expiry and drain status returned by core-elx rather than synthesizing incompatible local lease state.

#### Scenario: Upstream heartbeat extends the relay lease
- **GIVEN** core-elx accepts a relay heartbeat and returns an updated lease expiry
- **WHEN** the gateway updates its local relay session
- **THEN** the gateway SHALL persist the upstream lease expiry on the session
- **AND** downstream viewers and agents SHALL observe the upstream relay lease state rather than a gateway-local replacement
