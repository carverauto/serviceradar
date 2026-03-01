## ADDED Requirements
### Requirement: Multipath topology discovery
The system SHALL support multipath topology discovery using adaptive probing techniques to identify load-balanced paths (ECMP) between network nodes.

#### Scenario: Admin configures a multipath discovery job
- **GIVEN** an authenticated admin user
- **WHEN** they create a discovery job with:
    - `discovery_mode` set to "Multipath"
    - `max_ttl` (e.g., 30)
    - `probes_per_hop_initial` (e.g., 6)
    - `confidence_level` (e.g., 95%)
- **THEN** the job SHALL be persisted with the specified multipath parameters.

#### Scenario: Multipath discovery identifies multiple paths
- **GIVEN** a network with a 2-way ECMP load balancer between Hop A and Hop B
- **WHEN** a multipath discovery job is executed
- **THEN** the mapper SHALL discover both interfaces on the load balancer at the same TTL
- **AND** it SHALL report both paths in the topology results.

## MODIFIED Requirements
### Requirement: Mapper topology ingestion and graph projection
The system SHALL ingest mapper-discovered interfaces and topology links into CNPG and project them into an Apache AGE graph that models device/interface relationships, including multipath flows.

#### Scenario: Multipath link ingestion
- **GIVEN** mapper discovery results include multiple links between the same device pair for different flow IDs
- **WHEN** the results are ingested
- **THEN** the AGE graph SHALL represent these as distinct edges with flow-identifying metadata (e.g., protocol, port range)
- **AND** the graph SHALL accurately reflect the "topology diamonds" created by load balancers.
