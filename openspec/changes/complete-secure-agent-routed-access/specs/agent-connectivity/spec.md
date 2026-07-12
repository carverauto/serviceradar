## ADDED Requirements

### Requirement: Agents advertise effective remote-access capabilities
An agent SHALL advertise a remote-access protocol capability only when its applied configuration enables the protocol and every required local adapter/helper is installed, compatible, executable, healthy, and truthfully ready. Assignment metadata or compile-time linking alone MUST NOT advertise readiness.

#### Scenario: RDP assignment is present but helper is unready
- **WHEN** an agent has an RDP assignment but the helper is missing, unhealthy, incompatible, or lacks completed connector readiness
- **THEN** the agent omits `remote_access.rdp` and reports a sanitized adapter-unready reason

#### Scenario: Configuration disables a running adapter
- **WHEN** applied feature-set configuration disables a remote-access protocol
- **THEN** the agent withdraws the capability, rejects new opens, and closes or drains existing sessions according to revocation policy

### Requirement: Remote-access return frames preserve authenticated route ownership
Every remote-access terminal, graphical-media, activity, ready, error, and close frame returned from the edge SHALL be bound to the authenticated agent/gateway route that owns the session before the platform accepts it.

#### Scenario: Correct route returns a ready frame
- **WHEN** the selected authenticated agent returns a valid ready frame for its bound session
- **THEN** the platform may transition that session from opening to active

#### Scenario: Another agent guesses a session identifier
- **WHEN** a different authenticated agent returns a frame containing another session's identifier
- **THEN** the platform rejects the frame before broadcast, lifecycle mutation, recording, or browser delivery
