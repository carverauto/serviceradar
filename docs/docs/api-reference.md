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

## Run an SRQL query — `POST /api/query`

The `/api/query` endpoint executes a [ServiceRadar Query Language
(SRQL)](./srql-language-reference.md) query and returns the result set. SRQL
is read-only — only `SELECT`/`WITH` statements are generated and executed —
and results are scoped to the caller's authorization.

Send a JSON body with a `query` field. An optional `limit` caps the number of
rows returned.

```bash
curl -X POST https://your-serviceradar-host/api/query \
  -H "Authorization: Bearer $SERVICERADAR_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"query": "show devices order by last_seen desc", "limit": 50}'
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

## Other endpoints

The published [API specification](/api/) documents the remaining stable
endpoints, including:

- `GET /api/devices` and `GET /api/devices/{uid}` — browse the device
  inventory.
- `GET /api/devices/ocsf/export` — export devices as OCSF Device objects.
- `GET /health` — unauthenticated readiness probe.
- `GET /api/admin/*` — administrative endpoints (user management, RBAC role
  profiles, and more) that require admin privileges.

## Learn more

- [SRQL Tutorial](./srql-tutorial.md) — a hands-on introduction to writing
  SRQL queries.
- [SRQL Language Reference](./srql-language-reference.md) — the complete SRQL
  syntax reference.
- [Full API specification](/api/) — the rendered OpenAPI document.
