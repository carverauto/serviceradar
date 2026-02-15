## ADDED Requirements

### Requirement: TFTP Agent Capability
Agents with TFTP service enabled MUST declare `"tftp"` in their capabilities during enrollment via the `Hello` RPC. The core MUST record this capability and use it for command routing. The Settings UI MUST filter agent selection to only show agents with the `"tftp"` capability when creating TFTP sessions.

#### Scenario: Agent declares TFTP capability
- **WHEN** an agent with TFTP service enabled connects to the gateway
- **THEN** the agent includes `"tftp"` in its capabilities list in the `AgentHelloRequest`
- **AND** the core records the capability for command routing
- **AND** the Settings UI filters TFTP-eligible agents based on this capability

#### Scenario: Agent without TFTP capability
- **WHEN** an agent without TFTP service connects to the gateway
- **THEN** the agent does NOT include `"tftp"` in its capabilities
- **AND** the agent is not shown as a target option for TFTP sessions in the UI
