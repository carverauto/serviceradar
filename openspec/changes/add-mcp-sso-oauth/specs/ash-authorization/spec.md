## ADDED Requirements

### Requirement: MCP OAuth tokens execute as the consenting user
Access tokens issued by the MCP authorization-code grant MUST cause `/mcp` tool calls to run as the user who approved consent. The system MUST NOT substitute `SystemActor` for those calls. RBAC MUST match the mapped HTTP API for that user, the same as client-credentials MCP tokens.

#### Scenario: SSO user is the MCP actor
- **GIVEN** user U signed in via SSO and approved `serviceradar-mcp`
- **WHEN** that client's access token calls `list_devices`
- **THEN** Ash policy evaluation uses user U as actor
- **AND** the visible devices match `GET /api/devices` as U

#### Scenario: Viewer SSO user cannot escalate via MCP OAuth
- **GIVEN** user U is a viewer without `devices.view`
- **WHEN** U's MCP OAuth token calls `execute_srql` with `in:devices`
- **THEN** the tool is denied or returns no devices matching HTTP
- **AND** the implementation did not pass `authorize?: false`
