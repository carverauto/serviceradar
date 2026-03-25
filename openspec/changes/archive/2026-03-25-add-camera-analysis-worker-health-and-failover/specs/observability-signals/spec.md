## ADDED Requirements
### Requirement: Worker health and failover remain observable
The system SHALL emit observable worker health, selection, and failover outcomes for relay-scoped camera analysis dispatch.

#### Scenario: Worker health changes
- **GIVEN** a registered camera analysis worker
- **WHEN** the platform marks that worker healthy or unhealthy
- **THEN** observability signals SHALL preserve the worker identity
- **AND** SHALL preserve the health reason metadata when present

#### Scenario: Capability-targeted branch fails over
- **GIVEN** a relay-scoped analysis branch that fails over from one worker to another
- **WHEN** the platform performs the failover
- **THEN** observability signals SHALL preserve the originating relay session and branch identity
- **AND** SHALL preserve the original worker identity, replacement worker identity, and failover attempt count

#### Scenario: Terminal worker selection or failover failure
- **GIVEN** a relay-scoped analysis branch that cannot resolve or fail over to a healthy worker
- **WHEN** the platform terminates that selection path
- **THEN** observability signals SHALL preserve the relay session and branch identity
- **AND** SHALL emit an explicit bounded failure reason
