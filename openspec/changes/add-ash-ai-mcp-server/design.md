## Context

The Go MCP server (`pkg/mcp`) sat on the old core HTTP API, used a cluster-wide
`mcp.api_key` plus JWT, interpolated SRQL (CVE-class bug #2142), and died with
golang-core (issue #2307). The Dec 2025 blog claimed Phoenix would expose MCP
via `hermes_mcp`. That dependency was never added.

Today the supported programmatic path is:

1. Settings → API Credentials (OAuth2 client credentials)
2. `POST /oauth/token`
3. `Authorization: Bearer` on `POST /api/query` and `/api/devices*`

Ash policies, `ApiAuth`, OAuth scopes, and `SecurityEvent` already exist. MCP
must reuse them, not grow a parallel stack.

AshAi 0.8 ships `AshAi.Mcp.Router` over the MCP streamable HTTP transport
(protocol revisions `2026-07-28`, `2025-06-18`, `2025-03-26`). Tools are
declared on an Ash domain. The library's happy path (`tool :read, Device,
:read`) would expose Ash filters/loads that `/api/devices` does not, which is
exactly the side door this change forbids.

## Goals / Non-Goals

- Goals:
  - Production MCP endpoint on web-ng using `AshAi.Mcp.Router`.
  - Same actor, same RBAC, same query engine as the HTTP API.
  - Explicit read-only tool allowlist.
  - Append-only audit that operators can already read in Settings → Audit.
  - Default-off, credential-scoped (`mcp` OAuth scope), rate-limited.
- Non-Goals:
  - Restoring Go `pkg/mcp` or `hermes_mcp`.
  - Auto-exposing Ash resources or AshJsonApi as tools.
  - Write, admin, remote-access, or edge-onboarding tools.
  - A second OAuth 2.1 authorization server / DCR for Claude.ai (follow-up).
  - Unauthenticated `AshAi.Mcp.Dev` in prod or in Mix `prod` releases.
  - Using AshPaperTrail to version MCP calls.

## Decisions

- Decision: Use `AshAi.Mcp`, not `hermes_mcp`.
  - Rationale: AshAi is the maintained Ash integration, speaks streamable HTTP,
    and runs tools as Ash actions with `context.actor`. `hermes_mcp` is what
    the blog promised and never shipped.
  - Result: `{:ash_ai, "~> 0.8"}` on web-ng. No hermes package.

- Decision: MCP is a facade over existing HTTP/SRQL entry points, not a new
  data plane.
  - Rationale: If a tool can see a device the HTTP API cannot, or skip a
    controller limit, RBAC is fiction.
  - Result: Extract small shared functions used by both the Phoenix
    controllers and the AshAi tool actions. v1 mapping:

    | MCP tool            | HTTP API                         |
    |---------------------|----------------------------------|
    | `execute_srql`      | `POST /api/query`                |
    | `get_srql_catalog`  | `GET /api/srql/catalog`          |
    | `list_devices`      | `GET /api/devices`               |
    | `get_device`        | `GET /api/devices/:uid`          |

    Structured device tools bind identifiers as Ash/SRQL values (existing
    injection requirements). `execute_srql` is the documented free-form SRQL
    opt-in. Logs, events, and sweeps are queried through `execute_srql`, not
    extra tools.

- Decision: Do not declare `tool :read, ServiceRadar.Inventory.Device, :read`.
  - Rationale: AshAi resource tools expose public-attribute filter/sort/load
    that DeviceController does not. That is a second query language.
  - Result: Dedicated MCP tool resources whose actions only call the shared
    API functions, with `authorize?: true` and the request actor.

- Decision: Reuse existing API credentials; add an `mcp` OAuth scope.
  - Rationale: Operators already mint clients under Settings → API
    Credentials. A dedicated scope makes MCP opt-in per credential so a
    `read` automation token cannot suddenly speak MCP. User RBAC still
    applies on the underlying read.
  - Result: Pipeline is `:api_key_auth` + `RequireOauthScope` (`mcp`) + a
    plug that rejects identity-less legacy static keys (`user: nil` from
    `validate_legacy_api_key`). Browser session cookies are not accepted on
    `/mcp`.

- Decision: Execute as the credential's user, never `SystemActor`.
  - Rationale: `ash-authorization` already forbids substituting SystemActor
    on user-initiated HTTP. MCP is user-initiated HTTP.
  - Result: AshAi receives `conn.assigns.current_scope.user` as actor.
    Tool actions pass `scope: current_scope` into the shared API functions.

- Decision: Audit with `SecurityEvent`, not AshPaperTrail.
  - Rationale: `SecurityEvent`'s own moduledoc: paper trail is for row
    mutations (credentials, playbooks, console sessions); SecurityEvent is
    for signals that are not a versioned row. An MCP tool call is a read, not
    a Device/User update. PaperTrail on an append-only invocation table would
    be a version history of something that never updates.
  - Result: Add kinds `:mcp_auth_failed`, `:mcp_session_initialized`,
    `:mcp_tool_called`, `:mcp_tool_denied`. Record via
    `ServiceRadar.Security.Events.record/1` (non-blocking, already live-tailed
    on Settings → Audit → Events). Details include tool name, argument digest
    (not raw secrets), SRQL text for `execute_srql`, result status, row
    count, duration, protocol version, oauth client id. Do not persist result
    payloads.

- Decision: Feature flag default off; no Dev MCP in released images.
  - Rationale: The old Go server defaulted `Enabled: true`. AshAi.Mcp.Dev is
    unauthenticated by design.
  - Result: `mcp_enabled` runtime/Helm flag, false by default. Router returns
    404 when off. `AshAi.Mcp.Dev` is not installed in the endpoint.

- Decision: Dedicated rate-limit bucket `:mcp`.
  - Rationale: LLM clients retry and fan out. Reusing `api_default` would let
    an agent starve the rest of the API, or vice versa.
  - Result: Subject is oauth client id when present, else actor id, else IP.
    Denials are HTTP 429 and already flow through the RateLimit plug.

- Decision: Leave OAuth 2.1 DCR out of this change.
  - Rationale: AshAi's README recommends
    `ash_authentication_oauth2_server` for Claude.ai connectors. That is a
    second authorization server next to Guardian + existing `/oauth/token`.
    Hand-configured clients (Cursor, Claude Desktop, Grok) work with a Bearer
    token from the credentials we already issue.
  - Result: Document the Bearer header. A later change can add RFC 9728
    protected-resource metadata if we want hosted Claude connectors.

## Risks / Trade-offs

- Risk: `POST /api/query` currently puts `"actor"` on the SRQL request map,
  but `ServiceRadarWebNG.SRQL.query_request/1` only reads `"scope"` (used for
  dashboard search). SQL-backed entities are authenticated-but-not-Ash-filtered.
  - Mitigation: MCP must not invent a stricter or looser SRQL path. Extract one
    shared execute function that both QueryController and `execute_srql` call,
    passing `current_scope`. Closing the broader "SRQL SQL ignores Ash
    policies" gap is a separate change; this one must not make MCP the place
    it is silently fixed or silently bypassed.

- Risk: AshAi resource tools are the path of least resistance for later
  contributors.
  - Mitigation: Spec forbids generic resource tools. Code review / Credo or a
    unit test that the exposed tool list equals the allowlist.

- Risk: Prompt injection + a free-form SRQL tool.
  - Mitigation: v1 is read-only; SQL is already read-only in the NIF path;
    audit every `execute_srql`; `mcp` scope is explicit; default off.

- Risk: Result sets in the audit table.
  - Mitigation: Store counts and error class only.

## Migration Plan

1. Land code with `mcp_enabled=false`. No behavior change for existing APIs.
2. Operators who want it: set the flag, create an API client with scopes
   `read` and `mcp`, point the MCP client at `https://<host>/mcp`.
3. Rollback: set the flag false or remove `/mcp` from the router. No data
   migration. SecurityEvents remain as audit history.

## Open Questions

- None blocking. OAuth 2.1 DCR is explicitly deferred.
