## ADDED Requirements

### Requirement: MCP security event kinds
`ServiceRadar.Security.SecurityEvent` MUST accept kinds `:mcp_auth_failed`, `:mcp_session_initialized`, `:mcp_tool_called`, and `:mcp_tool_denied`. MCP MUST record those events through the existing non-blocking `SecurityEvents.record/1` recorder so they appear on Settings → Audit → Events for callers with `settings.audit.view`.

#### Scenario: Tool call is a SecurityEvent
- **WHEN** an MCP tool completes
- **THEN** a SecurityEvent of kind `:mcp_tool_called` or `:mcp_tool_denied` is persisted
- **AND** an operator with `settings.audit.view` can filter Events by that kind

#### Scenario: Auth failure is a SecurityEvent
- **WHEN** `/mcp` is called with a missing or invalid credential
- **THEN** a SecurityEvent of kind `:mcp_auth_failed` is recorded without blocking the 401 response

### Requirement: MCP rate-limit bucket
The shared rate limiter MUST define a `:mcp` bucket, independent of `:api_default`. The MCP Phoenix pipeline MUST apply `ServiceRadarWebNGWeb.Plugs.RateLimit` with that bucket.

#### Scenario: MCP 429 is isolated
- **WHEN** MCP requests exceed the `:mcp` limit for a subject
- **THEN** further MCP requests from that subject are HTTP 429
- **AND** other API buckets are unaffected
