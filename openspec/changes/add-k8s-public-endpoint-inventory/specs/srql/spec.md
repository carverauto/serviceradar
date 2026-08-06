## ADDED Requirements

### Requirement: public_endpoints SRQL entity
SRQL SHALL expose a queryable entity for Kubernetes public endpoint inventory (entity name `public_endpoints` or an equivalent documented alias) so operators can look up ownership by IP, hostname, port, protocol, namespace, and cluster identifier.

#### Scenario: Query by IP
- **WHEN** a user runs a SRQL query equivalent to `in:public_endpoints ip:23.138.124.7`
- **THEN** the engine returns matching current inventory rows for that IP

#### Scenario: Query by port and protocol
- **WHEN** a user filters public endpoints by port and protocol
- **THEN** only rows with matching listener or Service port and protocol are returned

#### Scenario: Query by hostname
- **WHEN** a user queries public endpoints by load balancer hostname
- **THEN** rows stored with that hostname match even if IP is null
