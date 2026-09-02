## ADDED Requirements

### Requirement: MCP requests execute as the credential user
For any MCP request authenticated by an API token or OAuth client, the system MUST execute Ash actions as the user who owns that credential. The system MUST NOT substitute `SystemActor` for authorization evaluation on MCP tool calls.

#### Scenario: MCP tool uses the token owner as actor
- **GIVEN** an OAuth client owned by user U with scope `mcp`
- **WHEN** a tool runs on `/mcp` with that client's access token
- **THEN** Ash policy evaluation uses user U as actor
- **AND** the action is not evaluated as a system actor

### Requirement: MCP cannot bypass HTTP authorization
An MCP tool MUST be denied whenever the same actor would be denied on the mapped HTTP API. `authorize?: false` is forbidden on MCP tool implementations.

#### Scenario: HTTP-denied device is MCP-denied
- **GIVEN** user U cannot read device D via `GET /api/devices/:uid`
- **WHEN** user U calls MCP `get_device` for D
- **THEN** the tool is denied or returns not-found matching HTTP
- **AND** the implementation did not pass `authorize?: false`
