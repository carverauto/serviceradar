---
sidebar_position: 12
title: MCP Integration
---

# Model Context Protocol (MCP)

ServiceRadar exposes a [Model Context Protocol](https://modelcontextprotocol.io/)
server from the web application using AshAi (`AshAi.Mcp.Router`). It is a
read-only facade over the existing HTTP API: tools call the same functions as
`POST /api/query` and `GET /api/devices`. They do not talk to CNPG or Ash
behind those endpoints.

The old Go `pkg/mcp` server is gone. This is not `hermes_mcp`.

## Enable the server

MCP is **off by default**. Set:

```bash
SERVICERADAR_MCP_ENABLED=true
```

Helm:

```yaml
webNg:
  mcpEnabled: "true"
```

`webNg.mcpEnabled` is the Helm lever. `extraEnv.SERVICERADAR_MCP_ENABLED` is ignored so a stored extraEnv workaround cannot shadow the flag. The chart must template `SERVICERADAR_MCP_ENABLED` from `mcpEnabled`; a published chart that predates that key will store `mcpEnabled` as an unused value and leave `/mcp` 404.

Demo (`values-demo.yaml`) sets `webNg.mcpEnabled: "true"` so Authentik SSO
against `https://demo.serviceradar.cloud/mcp` stays on across Image Updater
rolls. Do not put that flag only in `.argocd-source-serviceradar-demo-prod.yaml`;
write-back replaces the parameter list.

Until that flag is true, `https://<host>/mcp` returns HTTP 404.

## Authenticate

`/mcp` accepts a Guardian API JWT with the `mcp` scope. Browser session
cookies are rejected. Legacy static `SERVICERADAR_API_KEY` values (no user)
are rejected. The actor on every tool call is the user who authorized the
token; RBAC is the same as HTTP.

There are two ways to get that JWT.

### SSO (authorization code + PKCE)

This is the path SSO-mandated deployments should use. ServiceRadar is the
OAuth authorization server. The browser sign-in is the existing LoginPolicy
(Authentik OIDC on demo, OIDC/SAML in production). MCP clients do **not**
talk to the IdP token endpoint.

1. Enable MCP (`webNg.mcpEnabled: "true"`).
2. Point the client at `https://<host>/mcp`. Native clients (Codex, Claude
   Code, Grok HTTP OAuth) discover:

   - `/.well-known/oauth-protected-resource`
   - `/.well-known/oauth-authorization-server`

3. The client opens `/oauth/authorize` with `client_id=serviceradar-mcp`,
   PKCE S256, and an RFC 8252 loopback `redirect_uri`
   (`http://127.0.0.1:<port>/...` or `http://localhost:<port>/...`).
4. If you are not signed in, the UI sends you through the normal SSO
   (or local-password) login, then a consent page.
5. Approve. The client exchanges the code at `/oauth/token` and sends
   `Authorization: Bearer` on every MCP request.

Access tokens last **one hour**. A refresh token is issued only when
ServiceRadar can keep the grant bound to the IdP session:

- Local-password logins: refresh is TTL + rotation (default 8 hours).
- OIDC/SAML: the grant stores the IdP `sid` / SessionIndex and, when the
  IdP issued one, an encrypted IdP refresh token. Each MCP refresh confirms
  that IdP session is still alive. If you signed out of Authentik, or the
  IdP sent back-channel logout, refresh returns `invalid_grant` and you
  run `mcp login` again.
- If SSO produced no session id and no IdP refresh token, ServiceRadar
  issues the 1 hour access token only (fail closed). Add `offline_access`
  to the web OIDC scopes (Settings → Authentication) so Authentik issues a
  refresh token, and include the `sid` claim on the id_token.

Revoke a grant under **Settings → MCP Sessions**.

Example Codex (`~/.codex/config.toml`):

```toml
[mcp_servers.serviceradar]
url = "https://<host>/mcp"
```

Then `codex mcp login serviceradar`. Use `client_id=serviceradar-mcp` if
the client asks. Do not point the MCP client at Authentik's authorize or
token URLs.

Claude Code / Grok HTTP OAuth: set the MCP server URL to
`https://<host>/mcp` and complete the browser login the client opens.

Hosted Claude.ai connectors that require Dynamic Client Registration
(RFC 7591) are not supported yet.

### Client credentials (automation)

Farm01 and scripts that cannot open a browser still use
`grant_type=client_credentials`.

1. In the UI, open **Settings → API Credentials**.
2. Create a client with scopes **Read** and **MCP**.
3. Exchange the client id/secret for a JWT:

```bash
curl -X POST https://<host>/oauth/token \
  -d grant_type=client_credentials \
  -d client_id=YOUR_CLIENT_ID \
  -d client_secret=YOUR_CLIENT_SECRET
```

4. Send that token on every MCP request:

```
Authorization: Bearer <access_token>
```

Tokens last one hour. Request a new one when the current token expires.

SSO-mandated orgs should disable this for MCP:

```yaml
webNg:
  mcpClientCredentialsEnabled: "false"
```

That returns `unauthorized_client` when the granted scopes include `mcp`.
Clients that only request `read` / `write` are unchanged. The password
grant is not used for MCP.

Example Cursor / Claude Desktop / Grok config with a static bearer
(streamable HTTP):

```json
{
  "mcpServers": {
    "serviceradar": {
      "url": "https://<host>/mcp",
      "headers": {
        "Authorization": "Bearer <access_token>"
      }
    }
  }
}
```

Use protocol revision `2025-03-26` if the client has not been updated for
`2026-07-28`. Older clients may need a local MCP HTTP proxy.

## Tools (v1, read-only)

| Tool | Same as |
| --- | --- |
| `execute_srql` | `POST /api/query` (raw SRQL; the `query` argument is passed through) |
| `get_srql_catalog` | `GET /api/srql/catalog` |
| `list_devices` | `GET /api/devices` |
| `get_device` | `GET /api/devices/:uid` (`uid` is a bound identifier, not SRQL) |

AshAi nests each tool's action arguments under `input`. Example `tools/call`:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "get_device",
    "arguments": { "input": { "uid": "device-123" } }
  }
}
```

A flat `arguments` map is also accepted and wrapped the same way.

Logs, events, and sweeps are queried with `execute_srql`, for example
`in:logs time:last_1h limit:50`.

RBAC is the same as HTTP: a viewer sees what `GET /api/devices` would see.
There is no SystemActor path and no `authorize?: false`.

## Audit

Every initialize, tool call, denial, and auth failure is recorded on
**Settings → Audit → Events** as `mcp_session_initialized`, `mcp_tool_called`,
`mcp_tool_denied`, or `mcp_auth_failed`. OAuth consent, token issue, refresh,
grant revoke, IdP-session denial, and SLO revoke add `mcp_oauth_*` events.
Result payloads and IdP tokens are not stored.

## Related

- [API Reference](./api-reference.md) — HTTP auth and `POST /api/query`
- [Roles & Permissions](./rbac-and-roles.md)
