## ADDED Requirements
### Requirement: Relay session mutations remain agent-owned
The gateway SHALL bind relay session heartbeat, media upload, and close operations to the authenticated agent identity that opened the relay session. Session reference values such as `relay_session_id` and `media_ingest_id` SHALL NOT be sufficient by themselves to authorize relay mutation.

#### Scenario: Session owner mutates relay successfully
- **GIVEN** agent `A` opened relay session `S`
- **AND** the gateway recorded `A` as the owner of `S`
- **WHEN** agent `A` sends a valid media chunk, heartbeat, or close request for `S`
- **THEN** the gateway accepts the request

#### Scenario: Different agent is denied relay mutation
- **GIVEN** agent `A` opened relay session `S`
- **AND** agent `B` learns `S`'s `relay_session_id` and `media_ingest_id`
- **WHEN** agent `B` sends a media chunk, heartbeat, or close request for `S`
- **THEN** the gateway rejects the request
- **AND** the relay session remains bound to agent `A`
