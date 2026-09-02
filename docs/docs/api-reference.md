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

## Other endpoints

The published [API specification](/api/) documents the remaining stable
endpoints, including:

- `GET /api/devices` and `GET /api/devices/{uid}` — browse the device
  inventory.
- `GET /api/devices/ocsf/export` — export devices as OCSF Device objects.
- `GET` and `POST /api/v1/identity/resolve` — turn an address into a device
  UID without probing it. See [Resolve a Device
  Identity](./identity-resolve.md).
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
