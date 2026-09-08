## ADDED Requirements

### Requirement: MTR Path Graph Projection
The system SHALL project MTR trace paths into the `platform_graph` Apache AGE graph as `MTR_PATH` edges between Device or HopNode vertices, enabling topology visualization of network paths discovered by MTR probes.

#### Scenario: MTR path edges created from trace data
- **WHEN** an MTR trace result is ingested by the core system
- **THEN** for each consecutive responding hop pair (hop_n → hop_n+1), an `MTR_PATH` edge is MERGEd in `platform_graph`
- **AND** edge properties include `agent_id`, `avg_rtt_us`, `loss_pct`, `last_seen`, `protocol`
- **AND** hop IPs matching existing Device vertices reuse those vertices
- **AND** hop IPs not matching any known Device create HopNode vertices with `ip`, `hostname`, `asn`, `asn_org` properties

#### Scenario: Stale MTR path edges pruned
- **WHEN** an `MTR_PATH` edge has a `last_seen` timestamp older than the configured TTL (default 24 hours)
- **THEN** the edge is removed from `platform_graph` during the next pruning cycle
- **AND** orphaned HopNode vertices with no remaining edges are also removed
