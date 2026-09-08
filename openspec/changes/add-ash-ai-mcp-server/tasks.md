## 1. Dependencies and flags

- [x] 1.1 Add `{:ash_ai, "~> 0.8"}` to `elixir/web-ng/mix.exs` (and Bazel/hex lock as required). Do not add `hermes_mcp`.
- [x] 1.2 Add runtime flag `mcp_enabled` (env `SERVICERADAR_MCP_ENABLED`, default false) and a matching Helm value. Feature helper returns false unless explicitly enabled.
- [x] 1.3 Add RateLimiter bucket `:mcp` in `serviceradar_core` config.

## 2. Auth and routing

- [x] 2.1 Add OAuth scope `mcp` to API-credential create UI and client validation (alongside `read` / `write`).
- [x] 2.2 Add Phoenix pipeline `:mcp` that runs SecurityHeaders, ApiAuth, RequireOauthScope `mcp`, a plug that rejects identity-less legacy static keys, and RateLimit bucket `:mcp`.
- [x] 2.3 Mount `AshAi.Mcp.Router` at `/mcp` only when `mcp_enabled`. When disabled, `/mcp` is 404. Do not install `AshAi.Mcp.Dev`.
- [x] 2.4 Assign the authenticated user as Ash actor / `current_scope` for every MCP request. Never SystemActor. Never `authorize?: false`.

## 3. Shared API facade and tools

- [x] 3.1 Extract shared execute functions used by `QueryController`, `SrqlCatalogController`, and `DeviceController` (query, catalog, list devices, get device) so MCP cannot diverge.
- [x] 3.2 Add an Ash domain (for example `ServiceRadar.Mcp`) with AshAi tools that only call those shared functions. v1 allowlist: `execute_srql`, `get_srql_catalog`, `list_devices`, `get_device`.
- [x] 3.3 Bind structured scalar tool parameters (device uid, limits) as values. Do not concatenate them into SRQL. `execute_srql` is the only raw-SRQL tool and is documented as such.
- [x] 3.4 Enforce the same pagination/limit caps as the HTTP controllers. Read-only: no create/update/destroy tools.

## 4. Audit

- [x] 4.1 Add `SecurityEvent` kinds `:mcp_auth_failed`, `:mcp_session_initialized`, `:mcp_tool_called`, `:mcp_tool_denied`.
- [x] 4.2 Record non-blocking events on initialize, each tool call (success or error), auth failure, and RBAC/scope denial. Include actor, oauth client id, ip, tool, argument digest, SRQL text for `execute_srql`, status, row count, duration. Do not store result payloads or secrets.
- [x] 4.3 Do not add AshPaperTrail to MCP tool resources or invocation rows.

## 5. Tests

- [x] 5.1 Unauthenticated `/mcp` → 401. Disabled flag → 404.
- [x] 5.2 Legacy static API key (no user) → 401/403. Bearer without `mcp` scope → 403.
- [x] 5.3 Token with `mcp`+`read` as a viewer can list/get devices the HTTP API allows and cannot see what HTTP denies.
- [x] 5.4 `execute_srql` goes through the same shared function as `POST /api/query` (spy/stub). Injection payloads in `get_device` cannot widen the query.
- [x] 5.5 Tool allowlist test: exposed MCP tools equal the v1 list.
- [x] 5.6 Audit: a successful tool call and a denial each persist the expected SecurityEvent kind (flush the recorder in the test).
- [x] 5.7 Rate-limit: exceeding the `:mcp` bucket returns 429.

## 6. Cleanup and docs

- [x] 6.1 Remove unused `MCPConfigRef` / `CoreServiceConfig.MCP` from `go/pkg/models/config.go` if nothing else reads it.
- [x] 6.2 Add `docs/docs/mcp-integration.md` (enable flag, OAuth client with `mcp` scope, token exchange, example Cursor/Claude Desktop config, tool list, audit location). Link it from `docs/docs/api-reference.md` and `docs/sidebars.ts`.
- [x] 6.3 Correct the blog claim that `hermes_mcp` is in process, or add a one-line note that production MCP is AshAi.Mcp.
- [x] 6.4 Run `openspec validate add-ash-ai-mcp-server --strict` after any spec edit.
