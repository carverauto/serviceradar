## ADDED Requirements
### Requirement: Agent-routed remote console tunnel
The system SHALL provide a generic remote-console tunnel that routes operator sessions from the browser through web-ng, agent-gateway, and the selected edge agent before connecting to a target in that agent's reachable network.

#### Scenario: Reach device in segmented edge network
- **GIVEN** an operator is authorized to open a remote console for a device reachable only from a specific agent
- **WHEN** the operator starts the session from web-ng
- **THEN** web-ng SHALL create a session and route console frames through agent-gateway to that selected agent
- **AND** the agent SHALL connect to the target using the requested protocol adapter
- **AND** target credentials SHALL remain brokered to the agent-side adapter and SHALL NOT be sent to the browser.

#### Scenario: Reuse tunnel across protocols
- **GIVEN** ServiceRadar supports SSH console targets and later adds RDP or provider-native console targets
- **WHEN** a target declares protocol, renderer, agent, credential purpose, and capability metadata
- **THEN** the session lifecycle, authorization, audit, and gateway-to-agent routing SHALL be shared
- **AND** only the browser renderer and agent-side protocol adapter SHALL vary by protocol.
