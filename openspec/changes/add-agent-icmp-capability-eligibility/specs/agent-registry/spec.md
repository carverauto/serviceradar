## ADDED Requirements
### Requirement: Socket-Probe Capability Advertisement
The agent SHALL probe at startup whether it can open the sockets its ICMP sweep scanner and its MTR tracer need, and SHALL advertise each result as an explicit capability pair: `icmp` or `icmp.unavailable`, and `mtr` or `mtr.unavailable`.
The ICMP probe SHALL open the same sockets as the ICMP sweep scanner. The agent SHALL log the probe result, with the failure reason, once at startup, and SHALL reuse that result for every later capability report.

#### Scenario: Agent without raw-socket permission
- **GIVEN** an agent process that cannot open raw ICMP sockets
- **WHEN** the agent reports its capabilities
- **THEN** its capabilities SHALL contain `icmp.unavailable`
- **AND** SHALL NOT contain `icmp`

#### Scenario: MTR available through the unprivileged fallback
- **GIVEN** a Linux agent that cannot open raw ICMP sockets but can open unprivileged ICMP sockets
- **WHEN** the agent reports its capabilities
- **THEN** its capabilities SHALL contain `icmp.unavailable` and `mtr`

#### Scenario: Unavailable marker explained to operators
- **WHEN** an operator views an agent reporting `icmp.unavailable`
- **THEN** the agent detail page SHALL list the marker with an explanation that the agent cannot open raw ICMP sockets and receives no ICMP sweep work
