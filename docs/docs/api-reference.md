---
title: API Reference
---

# API Reference

ServiceRadar exposes a JSON HTTP API served by the ServiceRadar web
application. This page explains how to authenticate and how to run queries
against the API. The full, browsable specification is published at
[`/api/`](/api/).

## Authentication

Every API request must be authenticated. There are two supported methods:

- **Session** — when the API is called from a logged-in browser session, the
  existing session cookie is used automatically. This is what the
  ServiceRadar UI itself relies on.
- **API credentials** — for CLI tools, scripts, and external integrations,
  use a bearer token. Create one in the ServiceRadar UI under **Settings →
  API Credentials** (`/settings/api-credentials`), then send it on each
  request:

  ```
  Authorization: Bearer <your-token>
  ```

Treat API tokens like passwords: store them in a secret manager or
environment variable, never in source control.

To let an IDE or agent use those credentials over the Model Context
Protocol, add the `mcp` scope and see [MCP Integration](./mcp-integration.md).

## Rate limits

The authenticated `/api` scope uses the shared `api_default` request budget,
keyed by client IP rather than user or token. This includes queries, the SRQL
catalog, devices, camera and Proxmox console sessions, spatial endpoints,
`/api/horizon/*` proxy requests, and `/api/remote-access/*` session, WebRTC
signaling, file-transfer, host-key, recording, and desktop-target requests.
Requests from the same client IP share the budget with other routes using
`api_default`; changing endpoints or tokens does not create a separate
allowance. Separately declared scopes such as `/api/admin` are not covered by
this scope's limiter.

Authentication runs first: requests rejected as unauthenticated return `401`
without consuming this budget. Responses passing through the limiter include
`x-ratelimit-limit`, `x-ratelimit-remaining`, and `x-ratelimit-reset` headers.
When exhausted, JSON clients receive `429` with `error: "rate_limited"` and
`retry_after` in the response body. Wait for the `retry-after` header's number
of seconds before retrying, and reduce polling or request bursts.

For bucket configuration and defaults, see
[`ServiceRadar.Security.RateLimiter`](https://github.com/carverauto/serviceradar/blob/staging/elixir/serviceradar_core/lib/serviceradar/security/rate_limiter.ex).
This is a request budget, not a concurrent-session cap or a limit on traffic
inside an established stream.

## Run an SRQL query — `POST /api/query`

The `/api/query` endpoint executes a [ServiceRadar Query Language
(SRQL)](./srql-language-reference.md) query and returns the result set. SRQL is
ServiceRadar's read-only query language — the only query language you need; it is
the same language used throughout the UI. Results are scoped to the caller's
authorization.

Send a JSON body with a `query` field. An optional `limit` caps the number of
rows returned.

```bash
curl -X POST https://your-serviceradar-host/api/query \
  -H "Authorization: Bearer $SERVICERADAR_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"query": "in:devices", "limit": 50}'
```

A successful response looks like:

```json
{
  "results": [
    {
      "uid": "192.168.1.10",
      "hostname": "core-switch-01",
      "ip": "192.168.1.10",
      "last_seen": "2026-05-20T14:15:22Z"
    }
  ],
  "pagination": {
    "next_cursor": null,
    "prev_cursor": null,
    "limit": 50
  },
  "viz": null,
  "error": null
}
```

If the query is invalid, the API responds with `400 Bad Request` and an
`error` message:

```json
{ "error": "missing required field: query" }
```

For pagination across large result sets, pass the `next_cursor` value from a
response back as the `cursor` field (with `direction: "next"`) on the
following request.

### Retired sysmon JSON:API resources

The dedicated `/api/v2/cpu_metrics`, `/api/v2/memory_metrics`,
`/api/v2/disk_metrics`, `/api/v2/process_metrics`, their `_hourly` routes,
and `/api/v2/cpu_cluster_metrics` have been removed. Use `POST /api/query`
with the [sysmon SRQL queries](./srql-language-reference.md#aggregation-with-stats)
instead. The legacy CNPG tables, rollups and migrations remain in place.

## Discover the SRQL catalog — `GET /api/srql/catalog`

The `/api/srql/catalog` endpoint returns the canonical client-side reference for
SRQL entity names, grouped fields, control tokens, and operators. Browser
editors use it for completions and validation hints instead of embedding their
own field lists.

The endpoint uses the same authentication options as the rest of the API. It
also returns `ETag` and `Cache-Control: private, max-age=300, must-revalidate`
headers, so clients can send `If-None-Match` and reuse a cached catalog when the
server responds with `304 Not Modified`.

```bash
curl https://your-serviceradar-host/api/srql/catalog \
  -H "Authorization: Bearer $SERVICERADAR_API_TOKEN"
```

A successful response has this shape:

```json
{
  "version": "4c5459599ba5dac6e26738d1a06339f50be1937f7a647da5de457c63af95b452",
  "control_tokens": ["by:", "group:", "in:", "limit:", "sort:", "time:", "where"],
  "operators": [":", ":contains", ":equals", "!=", ">", ">=", "<", "<="],
  "entities": {
    "devices": {
      "label": "Devices",
      "fields": {
        "boolean": ["is_active", "is_available"],
        "numeric": ["risk_score"],
        "text": ["hostname", "ip", "vendor_name"],
        "time": ["last_seen_time"]
      }
    }
  }
}
```

`version` is the raw catalog digest. The `ETag` header wraps the same digest in
quotes for HTTP validation; send the quoted header value back in
`If-None-Match`.

## Alert rules and telemetry via JSON:API

The `/api/v2` JSON:API surface supports automated provisioning of stateful
alert rules and event promotion rules, alongside read-only log, service-status,
capacity-forecast, metric, and trace collections. Use `Accept: application/vnd.api+json` and,
for request bodies, `Content-Type: application/vnd.api+json`.

Stateful alert rules support listing, reading by ID, creating, updating,
and deleting at `/api/v2/stateful-alert-rules`. The `/active` collection
returns enabled rules. Send a JSON:API `data` object with
`type: "stateful-alert-rule"` and an `attributes` object; updates also carry
the rule's `id`. For rule behavior and incident controls, see
[Rule Builder](./rule-builder.md). Templates and alert engine state/history
are not exposed by this mount.

Event rules support listing and creating at `/api/v2/event-rules`, and
reading, updating, and deleting at `/api/v2/event-rules/{id}`. The
`/api/v2/event-rules/active` collection returns enabled rules. Send a
JSON:API `data` object with `type: "event-rule"` and an `attributes` object;
updates also carry the rule's `id`. For log promotion, set `source_type`
to `"log"` and supply the `match` criteria and `event` attributes. Creating,
updating, or deleting a rule immediately invalidates the log promotion rule
cache, so the next read reflects the mutation. Unauthenticated listing
returns an empty `data` array; unauthenticated mutations are denied.

Event rule reads (list, active list, and detail) require
`observability.rules.view`. Creating, updating, and deleting require
`observability.rules.create`, `observability.rules.update`, and
`observability.rules.delete`, respectively. Custom profiles can grant or
revoke each permission independently of the user's base role. A write
permission permits its operation without view permission; it does not grant
GET access. Without view permission, lists return an empty `data` array and
detail requests return 404. Profile changes affect subsequent authenticated
requests without replacing the bearer token. Built-in role defaults and the
internal system bypass remain supported. Rule permissions do not grant RBAC
profile management; see [Roles & Permissions](./rbac-and-roles.md).

Stateful alert rule reads retain the viewer-or-higher policy; mutations
require an operator or administrator, with the internal system bypass.
OAuth2 API bearer grants are enforced at the shared API boundary before
JSON:API dispatch and before every `:api_key_auth` controller. A `read` grant
permits `GET`, `HEAD`, and `OPTIONS` plus the audited read-only `POST`
exceptions (`/api/query`, `/api/admin/topology/route-analysis`, and
`/api/v1/identity/resolve` batch resolution), except the FieldSurvey ingest
upgrades (`GET /v1/field-survey/:session/rf-observations`, `pose-samples`,
and `spectrum-observations`), which require `write` or `admin` because the
upgrade claims a session and opens a stream (the `auth-check` probe stays a
read); every other mutation requires
`write` or `admin` as well as the credential owner's resource permissions.
Empty grants and narrow CLI grants cannot inherit the owner's full authority
on these routes. Through the UserAuth boundary, API bearer tokens are confined
to data routes under `/api`, `/topology`, and `/v1/stream` and cannot enter
browser credential authorization; routes mounted on `:api_key_auth` (including
`/v1/field-survey` reads) keep their mounted reach subject to the same
method gate. Browser sessions and user access tokens retain their existing
resource authorization.

Telemetry collections use bounded offset pagination even when no page is
requested. Use `page[limit]` and `page[offset]` and follow response pagination
links to retrieve subsequent pages. Treat each returned JSON:API `id` as an
opaque value, including composite IDs for telemetry; do not reconstruct IDs
from individual attributes. When the warehouse serves a log, timeseries, OTel
metric, or trace collection, a filter or sort on a column that table does not
store is rejected and the error names the field.

For the generated route inventory, accepted fields, and response schemas,
fetch `/api/v2/open_api` from your authenticated deployment. For the committed
schema's generation, path conventions, and drift checks,
see the [OpenAPI dump task](https://github.com/carverauto/serviceradar/blob/staging/elixir/web-ng/lib/mix/tasks/serviceradar/openapi/dump.ex).

## Horizon control-plane proxy

`GET`, `POST`, and `DELETE /api/horizon/{version}/*` forward allowlisted
Horizon control-plane requests to a configured Horizon upstream with
server-side Bearer key injection, so Horizon API keys are never exposed to the
browser. All routes sit inside the authenticated `/api` scope (browser session
or Bearer JWT/API token) and share the `api_default` rate-limit budget.

Allowlisted routes and required permissions:

| Method | Path | Upstream path | Permission |
| --- | --- | --- | --- |
| `GET` | `/api/horizon/v1/feeds/status` | `/api/v1/feeds/status` | `observability.events.view` |
| `GET` | `/api/horizon/v1/vendor-status` | `/api/v1/vendor-status` | `observability.events.view` |
| `GET` | `/api/horizon/v1/statuspages` | `/api/v1/statuspages` | `observability.events.view` |
| `GET` | `/api/horizon/v1/intel/lookup` | `/api/v1/intel/lookup` | `observability.events.view` |
| `GET` | `/api/horizon/v1/weathermap/timeline` | `/api/v1/weathermap/timeline` | `observability.events.view` |
| `GET` | `/api/horizon/v1/paths/dag` | `/api/v1/paths/dag` | `observability.traces.view` |
| `GET` | `/api/horizon/v1/bgp/sankey` | `/api/v1/bgp/sankey` | `observability.events.view` |
| `GET` | `/api/horizon/v1/bgp/zombies`, `/api/horizon/v2/bgp/zombies` | matching upstream version | `observability.events.view` |
| `GET` | `/api/horizon/{v1,v2}/bgp/watchlist`, `/api/horizon/{v1,v2}/bgp/watchlist/events` | `/api/v2/bgp/watchlist`, `/api/v2/bgp/watchlist/events` | `observability.events.view` |
| `POST` | `/api/horizon/{v1,v2}/bgp/watchlist` | `/api/v2/bgp/watchlist` | `settings.integrations.manage` |
| `DELETE` | `/api/horizon/{v1,v2}/bgp/watchlist/{id}` | `/api/v2/bgp/watchlist/{id}` | `settings.integrations.manage` |
| `GET` | `/api/horizon/v1/snapshots`, `/api/horizon/v1/snapshots/{id}` | matching upstream path | `observability.events.view` |
| `POST` | `/api/horizon/v1/snapshots` | `/api/v1/snapshots` | `settings.integrations.manage` |
| `DELETE` | `/api/horizon/v1/snapshots/{id}`, `/api/horizon/v1/snapshots/{id}/share` | matching upstream path | `settings.integrations.manage` |
| `GET` | `/api/horizon/v2/reports/isp-accountability`, `/api/horizon/v2/reports/isp-accountability/live`, `/api/horizon/v2/reports/isp-accountability/{id}` | matching upstream path | `observability.events.view` |
| `POST` | `/api/horizon/v2/reports/isp-accountability` | `/api/v2/reports/isp-accountability` | `settings.integrations.manage` |
| `DELETE` | `/api/horizon/v2/reports/isp-accountability/{id}` | `/api/v2/reports/isp-accountability/{id}` | `settings.integrations.manage` |
| `POST` | `/api/horizon/v2/agents/enrollment-tokens` | `/api/v2/agents/enrollment-tokens` | `settings.integrations.manage` |

Unlisted paths, unsupported methods, invalid IDs, and path-traversal or
percent-encoded slash/dot sequences return `404`. Query strings must use valid
RFC 3986 syntax without control characters and must not include a `token` query
parameter (`400` with `{"error": "invalid_query"}`); invalid `POST` JSON bodies
return `400` with `{"error": "invalid_body"}`.

Upstream configuration is resolved server-side from an enabled
`cloud.serviceradar.horizon-feed` plugin assignment first (`api_base_url` plus
`watchlist_api_key` or `api_key`, resolving `watchlist_api_key_secret_ref` and
`api_key_secret_ref` via `SecretRefs`), falling back to `:serviceradar_web_ng,
:horizon_proxy` application config or `SERVICERADAR_HORIZON_API_URL` and
`SERVICERADAR_HORIZON_API_KEY`. The upstream base URL must use `https://` with
no userinfo, query, fragment, or control characters, and must not target
loopback, unspecified, link-local, cloud metadata, multicast, or reserved
addresses (directly or via DNS resolution). Upstream redirects are disabled;
`GET` requests retry once after 50 ms on stale pooled-connection errors
(`:closed`, `:econnreset`, and HTTP/2 `:unprocessed` or `:pool_not_available`)
without retrying timeouts or upstream HTTP responses, while `POST` and `DELETE`
requests never retry. Non-`204` responses include `Cache-Control: no-store` and
a JSON `Content-Type`, and error states map to `503` (`horizon_not_configured`),
`502` (`horizon_upstream_invalid` or `horizon_upstream_unavailable`), and `504`
(`horizon_upstream_timeout`).

## Other endpoints

The published [API specification](/api/) documents the remaining stable
endpoints, including:

- `GET /api/devices` and `GET /api/devices/{uid}` — browse the device
  inventory.
- `GET /api/devices/ocsf/export` — export devices as OCSF Device objects.
- `GET` and `POST /api/v1/identity/resolve` — turn an address into a device
  UID without probing it. See [Resolve a Device
  Identity](./identity-resolve.md).
- `PUT` and `DELETE /api/devices/{uid}/source-facts/{fact_key}` — report or
  withdraw a device's switch port or VLAN as an external source. See [Device
  Source Facts API](./device-source-facts.md).
- `GET /api/v1/source-inventory` — read a collection-consistent, cursor-paginated
  snapshot emitted by an approved inventory plugin. The `source` and `instance`
  query parameters are required.
- `GET /health` — unauthenticated readiness probe.
- `GET /api/admin/*` — administrative endpoints (user management, RBAC role
  profiles, and more) that require admin privileges.

## Learn more

- [SRQL Tutorial](./srql-tutorial.md) — a hands-on introduction to writing
  SRQL queries.
- [SRQL Language Reference](./srql-language-reference.md) — the complete SRQL
  syntax reference.
- [Full API specification](/api/) — the rendered OpenAPI document.
