## ADDED Requirements

### Requirement: MCP OAuth events are SecurityEvents
The system SHALL record non-blocking `ServiceRadar.Security.SecurityEvent` rows for MCP OAuth authorize approve, authorize deny, authorization-code token issue, refresh, refresh-reuse revocation, grant revoke, IdP-session refresh denial, and IdP logout/SLO grant revoke, in addition to existing MCP kinds (`:mcp_auth_failed`, `:mcp_session_initialized`, `:mcp_tool_called`, `:mcp_tool_denied`). Events MUST NOT store authorization codes, refresh tokens, access tokens, PKCE verifiers, or IdP refresh tokens.

#### Scenario: Successful authorize is auditable
- **WHEN** a user approves MCP consent
- **THEN** a SecurityEvent exists with the user, client id, and scopes
- **AND** no code or token value is stored in details

#### Scenario: Refresh reuse is auditable
- **WHEN** a rotated refresh token is presented again
- **THEN** a SecurityEvent records the family revocation
- **AND** an operator with audit view can see it on Settings → Audit → Events

#### Scenario: IdP session loss is auditable
- **WHEN** MCP refresh is denied because the IdP session is gone
- **OR** SLO revokes MCP grants
- **THEN** a SecurityEvent records the user, client, and IdP session id
- **AND** no IdP token values are stored

### Requirement: MCP OAuth endpoints are rate-limited
`GET /oauth/authorize` and `POST /oauth/token` for MCP grants MUST use dedicated rate-limit buckets, independent of the `:mcp` tool bucket and of `:oauth_client_credentials`.

#### Scenario: Token abuse does not starve MCP tools
- **WHEN** `/oauth/token` exceeds its bucket for a subject
- **THEN** further token requests from that subject are limited
- **AND** `/mcp` tool calls for a different subject are unaffected
