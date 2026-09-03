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

The old Go `pkg/mcp` server is gone. This is not `hermes_mcp`. The URL is
always `https://<host>/mcp`, never `/api/mcp`.

MCP is **off by default**. Until it is enabled, `/mcp` returns HTTP 404.

## Enable on Kubernetes (Helm)

The chart templates `SERVICERADAR_MCP_*` from first-class `webNg` keys.
`webNg.extraEnv.SERVICERADAR_MCP_ENABLED` is ignored so a stored extraEnv
workaround cannot shadow the flag.

```yaml
webNg:
  mcpEnabled: "true"
  # SSO-mandated orgs should set this to "false".
  mcpClientCredentialsEnabled: "true"
  mcpRefreshTtlSeconds: "28800"
  # Issuer and resource metadata use this HTTPS origin.
  publicUrl: "https://serviceradar.example.com"
```

Set `publicUrl` to the URL users type in a browser (no trailing path). OAuth
discovery and the `WWW-Authenticate` `resource_metadata` URL are built from
it.

The bundled chart must be new enough to template those keys. A published chart
that predates `webNg.mcpEnabled` will store the value unused and leave `/mcp`
404. Use the chart from this repo (or a release that includes the MCP env
block in `templates/web.yaml`).

### Existing install

```bash
helm upgrade serviceradar ./helm/serviceradar \
  -n <namespace> \
  --reuse-values \
  --set webNg.mcpEnabled="true"
```

`--reuse-values` keeps cluster-specific settings (VIPs, storage, pull
secrets). For a one- or two-service image pin, keep using `image.digests.*`
as usual; enabling MCP does not require moving `global.imageTag`.

### Demo overlay

`helm/serviceradar/values-demo.yaml` sets `webNg.mcpEnabled: "true"` so
carverauto `demo` (Authentik SSO at `https://demo.serviceradar.cloud/mcp`)
stays on across Image Updater write-back. Do not put that flag only in
`.argocd-source-serviceradar-demo-prod.yaml`; write-back replaces the
parameter list.

### Argo CD

If the Application uses `valueFiles: [values-demo.yaml]` (demo does), put
`mcpEnabled` in that overlay file. A live `kubectl patch` of
`spec.source.helm.parameters` does not reach Helm.

## Enable on Docker Compose

Compose passes the same runtime env web-ng already reads. Default is off.

```bash
SERVICERADAR_MCP_ENABLED=true docker compose up -d web-ng
```

Or set them in the environment / `.env` next to `APP_TAG`:

```bash
SERVICERADAR_MCP_ENABLED=true
SERVICERADAR_MCP_CLIENT_CREDENTIALS_ENABLED=true
SERVICERADAR_MCP_REFRESH_TTL_SECONDS=28800
```

The `web-ng` service in `docker-compose.yml` forwards those variables. After
the container is healthy, MCP is at `https://localhost/mcp` through Caddy
(or `http://localhost:4000/mcp` if you talk to Phoenix directly). Compose
login is local password unless you have configured SSO.

Restart only web-ng after flipping the flag; you do not need to recreate
CNPG or NATS.

## Check that it is on

Replace the host with yours (`demo.serviceradar.cloud`,
`serviceradar.k8s-farm.carverauto.dev`, `localhost`, …).

```bash
curl -sS https://<host>/.well-known/oauth-protected-resource
curl -sS https://<host>/.well-known/oauth-authorization-server
curl -sS -D - -o /dev/null -X POST https://<host>/mcp \
  -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
```

Expect:

- both well-known documents HTTP 200
- unauthenticated `POST /mcp` HTTP 401 with
  `WWW-Authenticate: Bearer realm="mcp", resource_metadata="https://<host>/.well-known/oauth-protected-resource"`

HTTP 404 means the flag is still off (or you hit `/api/mcp`, which does not
exist).

## Connect an agent (SSO)

This is the path SSO-mandated deployments should use. ServiceRadar is the
OAuth authorization server. The browser sign-in is the existing LoginPolicy
(Authentik on demo, OIDC/SAML in production, local password where SSO is
off). MCP clients do **not** talk to the IdP token endpoint.

Shared rules for every client below:

- Server URL: `https://<host>/mcp` (not `/api/mcp`, not Authentik).
- `client_id`: `serviceradar-mcp` when the client asks.
- Redirect URI: RFC 8252 loopback only (`http://127.0.0.1:<port>/...` or
  `http://localhost:<port>/...`).
- Configure **one** server name per host. Two names for the same URL (for
  example `serviceradar` and `serviceradar-demo`) make the client start both
  and look like a failure.
- Native clients discover
  `/.well-known/oauth-protected-resource` and
  `/.well-known/oauth-authorization-server`.

Access tokens last **one hour**. A refresh token is issued only when
ServiceRadar can keep the grant bound to the IdP session:

- Local-password logins: refresh is TTL + rotation (default 8 hours).
- OIDC/SAML: the grant stores the IdP `sid` / SessionIndex and, when the
  IdP issued one, an encrypted IdP refresh token. Each MCP refresh confirms
  that IdP session is still alive. Sign out of Authentik, or an IdP
  back-channel logout, and the next refresh is `invalid_grant` — run
  `mcp login` again.
- If SSO produced no session id and no IdP refresh token, ServiceRadar
  issues the 1 hour access token only (fail closed). Add `offline_access`
  to the web OIDC scopes (Settings → Authentication) so Authentik issues a
  refresh token, and include the `sid` claim on the id_token.

Revoke a grant under **Settings → MCP Sessions**.

### Codex

```bash
codex mcp add serviceradar \
  --url https://<host>/mcp \
  --oauth-client-id serviceradar-mcp

codex mcp login serviceradar
```

Or write `~/.codex/config.toml` and then login:

```toml
[mcp_servers.serviceradar]
url = "https://<host>/mcp"

[mcp_servers.serviceradar.oauth]
client_id = "serviceradar-mcp"
```

```bash
codex mcp login serviceradar
```

`codex mcp list` should show `serviceradar` with Auth `OAuth` after login.
Restart the Codex session so it re-initializes against `/mcp`.

### Claude Code

```bash
claude mcp add --transport http --scope user \
  --client-id serviceradar-mcp \
  serviceradar https://<host>/mcp

claude mcp login serviceradar
```

`--scope user` writes `~/.claude.json` so every project sees the server.
`--scope local` (the default) keeps it in the current project only.

`claude mcp login --no-browser serviceradar` prints the authorize URL for
SSH/headless sessions; paste the loopback redirect back when prompted.

Hosted Claude.ai connectors that require Dynamic Client Registration
(RFC 7591) are not supported yet. Use Claude Code on the machine that can
open a loopback callback.

### Grok

```bash
grok mcp add --transport http --scope user \
  serviceradar https://<host>/mcp
```

Start a Grok session that uses that server, or:

```bash
grok mcp doctor serviceradar
```

Complete the browser window the client opens. Grok treats an `https://` URL
as HTTP transport; do not add a Bearer header if you are using OAuth login.

### What the browser should do

1. The client opens `/oauth/authorize` with PKCE S256.
2. Redirect to `/users/log-in` if you are not signed in.
3. Sign in (Enterprise SSO on demo, local password on Compose / farm01).
4. ServiceRadar consent page → Approve.
5. Browser returns to `http://127.0.0.1:<port>/...`. The client stores a
   Guardian JWT with scopes `mcp` and `read`.

If the browser lands on Authentik's own authorize/token URLs in the **MCP
server config**, the config is wrong. Authentik is only the login UI.

### After login

Ask the agent to look up SRQL (`lookup_srql_docs` with `devices` or `time:`)
or to run `in:devices limit:5`. Tools run as **your** user; RBAC matches the
HTTP API.

## Client credentials (automation)

Scripts and clusters that cannot open a browser still use
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
(streamable HTTP) when you are **not** using the OAuth login above:

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
| `lookup_srql_docs` | Search grammar, cookbook, and catalog by short query (entity, operator, or task). Prefer this over dumping the catalog. |
| `get_srql_catalog` | `GET /api/srql/catalog`. Pass `entity` (for example `devices`) to load one entity; the full catalog is large. |
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

MCP `initialize` instructions tell the agent to call `lookup_srql_docs`
(like looking up crate docs) then `execute_srql`. Full grammar/cookbook
resources remain available for clients that read MCP resources. Do not
expect the model to know SRQL from tool names alone.

Example `lookup_srql_docs` queries: `devices`, `time:`, `ssh`, `stats`,
`cpu`. The tool returns the matching sections only, not the whole catalog.

RBAC is the same as HTTP: a viewer sees what `GET /api/devices` would see.
There is no SystemActor path and no `authorize?: false`.

## Resources (SRQL teaching documents)

These are MCP resources (`resources/list` / `resources/read`), not tools.
They are compact agent-facing distillates, not the human Docusaurus pages.

| URI | What it is |
| --- | --- |
| `serviceradar://srql/grammar` | Token shape, operators, time, stats, bucket, common mistakes |
| `serviceradar://srql/entities` | Live entity-id table generated from the catalog |
| `serviceradar://srql/cookbook` | Copy-paste recipes (devices, logs, flows, metrics, advisories/CPE) |

The human [SRQL Tutorial](./srql-tutorial.md), [SRQL Reference](./srql-language-reference.md),
and [SRQL Cookbook](./srql-cookbook.md) stay in the docs site. Do not dump those
pages into `get_srql_catalog`; the catalog is a field inventory.

## Audit

Every initialize, tool call, denial, and auth failure is recorded on
**Settings → Audit → Events** as `mcp_session_initialized`, `mcp_tool_called`,
`mcp_tool_denied`, or `mcp_auth_failed`. OAuth consent, token issue, refresh,
grant revoke, IdP-session denial, and SLO revoke add `mcp_oauth_*` events.
Result payloads and IdP tokens are not stored.

## Related

- [API Reference](./api-reference.md) — HTTP auth and `POST /api/query`
- [Roles & Permissions](./rbac-and-roles.md)
- [Kubernetes (Helm)](./helm-configuration.md)
- [Docker Compose](./docker-setup.md)
- [Authentication](./auth-configuration.md)
