# Change: Add an AshAi MCP server that only calls existing APIs

## Why

ServiceRadar used to ship a Go MCP server on the old core API. That process is
gone, the Elixir replacement was announced (`hermes_mcp`) and never built, and
the user docs were deleted. Operators and IDE agents have no supported way to
talk MCP to a live deployment.

A second MCP implementation that talks to Ash or CNPG behind the HTTP API
would create a privilege path the rest of the product cannot see, rate-limit,
or audit. The replacement has to be a facade over the same authenticated
Phoenix/SRQL surfaces that `/api/query` and `/api/devices` already enforce.

## What Changes

- Add `ash_ai` and mount `AshAi.Mcp.Router` on web-ng at `/mcp` (streamable
  HTTP). Do **not** add `hermes_mcp`.
- MCP is **off by default**. Enabling it is an explicit runtime/Helm flag.
- Authenticate with the existing API-credential stack (OAuth2 client
  credentials / user API tokens). Require a dedicated `mcp` OAuth scope.
  Reject anonymous access, browser sessions, and the legacy identity-less
  `SERVICERADAR_API_KEY` static keys.
- Tools are an explicit allowlist. Each tool calls a shared function that the
  matching HTTP controller already uses (`POST /api/query`,
  `GET /api/srql/catalog`, `GET /api/devices`, `GET /api/devices/:uid`). No
  generic Ash resource CRUD, no `authorize?: false`, no SystemActor, no raw
  SQL.
- v1 tools are **read-only**.
- Audit every initialize, tool call, denial, and auth failure on the existing
  `SecurityEvent` stream (Settings → Audit → Events). Do **not** use
  AshPaperTrail for tool invocations; paper trail versions row mutations, and
  MCP calls are not mutations.
- Rate-limit the MCP pipeline with a dedicated `mcp` bucket.
- Restore accurate `docs/docs` for how to enable, authenticate, and configure
  a client. Remove the leftover Go `MCPConfigRef` dead field.

## Impact

- Affected specs: `mcp`, `ash-authorization`, `platform-security`
- Affected code:
  - `elixir/web-ng` (router, MCP pipeline, shared API facade, AshAi domain/tools, tests, docs UI copy on API credentials)
  - `elixir/serviceradar_core` (`SecurityEvent` kinds, RateLimiter bucket, OAuth `mcp` scope, RBAC catalog copy)
  - `docs/docs/mcp-integration.md` (new), `docs/docs/api-reference.md`, `docs/sidebars.ts`
  - `go/pkg/models/config.go` (remove unused `MCPConfigRef`)
  - Helm/runtime flags to enable `/mcp`
- Migration: none for existing data. MCP stays disabled until an operator
  turns it on and issues a credential with the `mcp` scope.
- Out of scope: AshAuthentication OAuth 2.1 / dynamic client registration for
  Claude.ai connectors; exposing AshJsonApi resources as tools; write/admin
  tools; the unauthenticated `AshAi.Mcp.Dev` plug in any released image.
