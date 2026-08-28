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

Until that flag is true, `https://<host>/mcp` returns HTTP 404.

## Authenticate

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

The `mcp` scope is required. Browser session cookies are not accepted. Legacy
static `SERVICERADAR_API_KEY` values (no user) are rejected.

Tokens last one hour. Request a new one when the current token expires.

## Configure a client

Example Cursor / Claude Desktop / Grok config (streamable HTTP):

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
`mcp_tool_denied`, or `mcp_auth_failed`. Result payloads are not stored.

## Related

- [API Reference](./api-reference.md) — HTTP auth and `POST /api/query`
- [Roles & Permissions](./rbac-and-roles.md)
