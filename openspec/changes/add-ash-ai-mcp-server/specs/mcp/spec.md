## ADDED Requirements

### Requirement: MCP server is AshAi over streamable HTTP
The system SHALL expose a Model Context Protocol server using `AshAi.Mcp.Router` on the web-ng Phoenix endpoint at `/mcp` (streamable HTTP). The server MUST NOT use `hermes_mcp` or restore the deleted Go `pkg/mcp` process.

#### Scenario: Enabled server speaks MCP on /mcp
- **GIVEN** MCP is enabled for the deployment
- **WHEN** an authenticated MCP client sends a supported initialize or tools/list request to `/mcp`
- **THEN** the server responds according to the MCP streamable HTTP transport
- **AND** the implementation is `AshAi.Mcp.Router`

#### Scenario: Disabled server is absent
- **GIVEN** MCP is not enabled (the default)
- **WHEN** any client requests `/mcp`
- **THEN** the response is HTTP 404
- **AND** no MCP tools are reachable

### Requirement: MCP is disabled by default
MCP MUST be disabled unless an operator explicitly enables it via runtime configuration (environment variable / Helm value). Released images MUST NOT mount `AshAi.Mcp.Dev`.

#### Scenario: Default install has no MCP
- **GIVEN** a stock Helm or Compose install with no MCP flag
- **WHEN** a client requests `/mcp`
- **THEN** the response is HTTP 404

#### Scenario: Dev plug is not in production
- **GIVEN** a Mix `prod` release
- **WHEN** the endpoint module is inspected
- **THEN** `AshAi.Mcp.Dev` is not in the plug pipeline

### Requirement: MCP authenticates as an API credential with mcp scope
Every MCP request MUST authenticate through the existing web-ng API-credential stack (OAuth2 client-credentials access token or user API token). The credential MUST include the `mcp` OAuth scope. Browser session cookies MUST NOT authenticate `/mcp`. Legacy identity-less static API keys (`SERVICERADAR_API_KEY` / `user: nil`) MUST be rejected.

#### Scenario: Bearer with mcp scope is accepted
- **GIVEN** MCP is enabled
- **AND** an OAuth client owned by a user has scopes that include `mcp`
- **WHEN** the client presents a valid `Authorization: Bearer` access token on `/mcp`
- **THEN** the request is authenticated as that user

#### Scenario: Missing mcp scope is rejected
- **GIVEN** a valid API access token whose scopes do not include `mcp`
- **WHEN** the token is used on `/mcp`
- **THEN** the response is HTTP 403
- **AND** a `SecurityEvent` of kind `:mcp_auth_failed` or `:mcp_tool_denied` is recorded

#### Scenario: Anonymous MCP is rejected
- **GIVEN** MCP is enabled
- **WHEN** a client calls `/mcp` with no credentials
- **THEN** the response is HTTP 401

#### Scenario: Legacy static API key cannot use MCP
- **GIVEN** `SERVICERADAR_API_KEY` is configured
- **WHEN** a client sends that key on `/mcp`
- **THEN** the request is denied
- **AND** no MCP tool runs as a nil user

### Requirement: MCP tools are an explicit read-only allowlist
The MCP server MUST expose only an explicit allowlist of tools. v1 MUST be `execute_srql`, `get_srql_catalog`, `list_devices`, and `get_device`. The server MUST NOT auto-expose Ash resources, AshJsonApi endpoints, or write/admin/remote-access actions as tools.

#### Scenario: Allowlist is the only exposed surface
- **WHEN** an authenticated client calls tools/list
- **THEN** the returned names are exactly the v1 allowlist

#### Scenario: Generic Ash resource tools are not registered
- **GIVEN** `ServiceRadar.Inventory.Device` has Ash read actions
- **WHEN** an MCP client lists tools
- **THEN** no tool is a generic Ash `read`/`create`/`update`/`destroy` of that resource

### Requirement: MCP tools call the same API functions as HTTP
Each MCP tool MUST invoke the same shared function the corresponding HTTP controller uses. MCP MUST NOT query CNPG, Ash, or SRQL through a path the HTTP API does not use. MCP MUST pass the authenticated user's `current_scope` (or equivalent) and MUST set `authorize?: true`. MCP MUST NOT substitute `SystemActor` and MUST NOT pass `authorize?: false`.

#### Scenario: execute_srql shares QueryController's path
- **WHEN** an MCP client calls `execute_srql`
- **THEN** execution goes through the same function as `POST /api/query`
- **AND** the function receives the authenticated user's scope

#### Scenario: get_device shares DeviceController's path
- **WHEN** an MCP client calls `get_device` with a uid
- **THEN** the lookup goes through the same function as `GET /api/devices/:uid`
- **AND** a uid the HTTP API would hide is also hidden from MCP

#### Scenario: MCP cannot run as SystemActor
- **WHEN** any MCP tool runs
- **THEN** Ash sees the credential's user as actor
- **AND** the action is not authorized as a system actor

### Requirement: MCP respects the caller's RBAC
A tool MUST succeed only when the same caller would succeed on the mapped HTTP endpoint. Viewer-limited users MUST receive only viewer-visible data. Limits and pagination caps MUST match the HTTP controllers.

#### Scenario: Viewer sees the same devices over MCP and HTTP
- **GIVEN** a viewer-role user with an `mcp`-scoped API token
- **WHEN** they list devices via MCP and via `GET /api/devices`
- **THEN** the visible uid sets are equal

#### Scenario: HTTP 403 is MCP 403
- **GIVEN** a caller who cannot read a given device over HTTP
- **WHEN** they call `get_device` for that uid
- **THEN** the tool is denied or returns not-found according to the HTTP behavior
- **AND** no extra fields are returned

### Requirement: MCP records a SecurityEvent audit trail
The system SHALL record a `ServiceRadar.Security.SecurityEvent` for MCP authentication failures, session initialize, each tool call, and each tool denial. Events MUST be written through the existing non-blocking `SecurityEvents.record/1` path so they appear on Settings → Audit → Events. Events MUST include actor, oauth client id when present, client IP, tool name, argument digest, result status, and duration. `execute_srql` events MUST include the SRQL text. Events MUST NOT store result payloads or secret values. MCP tool invocations MUST NOT be versioned with AshPaperTrail.

#### Scenario: Successful tool call is auditable
- **WHEN** `list_devices` succeeds
- **THEN** a `SecurityEvent` of kind `:mcp_tool_called` exists with actor, tool name, and status

#### Scenario: Denied tool call is auditable
- **WHEN** a tool is denied for RBAC or missing scope
- **THEN** a `SecurityEvent` of kind `:mcp_tool_denied` or `:mcp_auth_failed` exists
- **AND** the event is visible to an operator with `settings.audit.view`

#### Scenario: Result payloads are not stored
- **WHEN** `execute_srql` returns rows
- **THEN** the SecurityEvent details include row count and MUST NOT include the result set

#### Scenario: Paper trail is not used for invocations
- **WHEN** an MCP tool runs
- **THEN** no AshPaperTrail version row is created for that invocation

### Requirement: MCP is rate-limited on its own bucket
MCP requests MUST pass through `ServiceRadarWebNGWeb.Plugs.RateLimit` using a dedicated `:mcp` bucket, independent of `api_default`.

#### Scenario: MCP limit does not share api_default
- **WHEN** MCP traffic exceeds the `:mcp` bucket
- **THEN** the response is HTTP 429 with retry-after
- **AND** `api_default` counters are unchanged

## MODIFIED Requirements

### Requirement: MCP tool parameters are quoted as SRQL literals
The MCP server MUST treat structured tool parameters that represent scalar string values (for example identifiers, names, and timestamps) as bound values when constructing SRQL queries, and MUST NOT concatenate raw parameter text into SRQL fragments.

#### Scenario: Device ID input cannot widen a query
- **GIVEN** a `get_device` request with `device_id` containing quotes and operators (for example `device' OR '1'='1`)
- **WHEN** the MCP server constructs the lookup
- **THEN** the identifier is a single bound value representing the entire input
- **AND** the query structure is not modified by the input (no additional boolean conditions are introduced)

#### Scenario: Gateway ID input cannot escape its filter
- **GIVEN** a request that filters by `gateway_id` via a structured parameter (not a raw SRQL filter string)
- **WHEN** the MCP server constructs the SRQL query
- **THEN** `gateway_id` is represented as a bound value and cannot terminate or extend the filter expression

### Requirement: MCP uses centralized parameter binding for scalar values
The MCP server MUST implement and use a single internal parameter binding mechanism for structured scalar values across all tools and shared query builders. Structured tools MUST reuse the HTTP/Ash binding already used by the mapped API, not a parallel interpolator.

#### Scenario: Consistent quoting across tools
- **GIVEN** multiple MCP tools that include scalar string parameters in constructed SRQL queries
- **WHEN** each tool constructs its SRQL query
- **THEN** all scalar string parameters are bound using the same internal mechanism as the HTTP API

### Requirement: Free-form SRQL is explicitly opt-in
Tools that accept free-form SRQL strings MUST explicitly label the parameter as raw SRQL input (for example `query` or `filter`) and MUST document that the value is passed through. The only v1 tool that accepts raw SRQL is `execute_srql`. Tools that accept structured scalar parameters MUST NOT interpret those parameters as SRQL fragments.

#### Scenario: Structured parameters are not treated as raw SRQL
- **GIVEN** a tool that accepts `device_id` or `gateway_id` as a structured parameter
- **WHEN** the parameter contains SRQL operators
- **THEN** the parameter is treated as a literal value, not parsed as SRQL syntax

#### Scenario: execute_srql is documented as raw SRQL
- **WHEN** a client lists tools
- **THEN** `execute_srql` describes its `query` argument as a raw SRQL string passed through to `POST /api/query`

### Requirement: MCP has regression tests for injection payloads
The MCP codebase MUST include tests that assert SRQL generated from structured tool parameters is safe against quote-based injection payloads.

#### Scenario: Regression tests detect unsafe interpolation
- **GIVEN** a known injection payload containing quotes and boolean operators
- **WHEN** `get_device` (or another structured tool) is exercised in a test
- **THEN** the produced lookup binds the payload as a single parameter value
- **AND** the test fails if the payload alters the query structure
