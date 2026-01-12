## MODIFIED Requirements
### Requirement: Distributed Gateway Coordination
The system SHALL coordinate polling jobs across distributed gateway nodes using Horde, and selection SHALL be tenant-scoped.

#### Scenario: Gateway discovery
- **GIVEN** multiple gateway nodes in the ERTS cluster for tenant "acme"
- **WHEN** a polling job needs execution for tenant "acme"
- **THEN** the system SHALL query Horde.Registry for available gateways in tenant "acme"
- **AND** select a gateway matching the required partition

#### Scenario: Gateway failover
- **GIVEN** a polling job assigned to gateway node P1 for tenant "acme"
- **WHEN** gateway P1 becomes unavailable mid-execution
- **THEN** Horde SHALL detect the failure
- **AND** the job SHALL be reassigned to another available gateway for tenant "acme"
