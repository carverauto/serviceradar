## ADDED Requirements

### Requirement: Agent-terminated provider console streams
Provider-native guest-console traffic SHALL be terminated by the policy-selected
edge agent and relayed as bounded, typed remote-access frames over the existing
authenticated agent path. The browser SHALL not establish a direct connection
to a provider endpoint or select a different agent, target, or protocol.

#### Scenario: Guest console remains route-bound
- **GIVEN** a guest-terminal session is assigned to one agent and route
- **WHEN** the browser sends terminal input, resize, or close frames
- **THEN** the platform SHALL forward only frames bound to that session and
  selected agent
- **AND** the agent SHALL reject frames with a mismatched target, route, or
  protocol before provider I/O

#### Scenario: Provider loss closes the browser session
- **GIVEN** an edge agent has an active provider terminal connection
- **WHEN** the agent loses its authenticated platform route or the provider
  terminal connection ends
- **THEN** the agent SHALL close the provider connection and notify the
  browser through the bound session
- **AND** no other agent or provider endpoint SHALL take over the session
