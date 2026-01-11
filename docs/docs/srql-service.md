---
sidebar_position: 32
title: SRQL Service Configuration
---

# SRQL Service Configuration

The SRQL microservice powers `/api/query` and `/translate` by translating SRQL statements to CNPG SQL. It sits behind the same HTTPS ingress as the web UI (Caddy/Ingress). This page documents the authentication and rate-limiting controls so operators know how to secure the endpoint.

## API Key Authentication

SRQL protects every write/read route with the `X-API-Key` header whenever an API key is configured.

| Variable | Description | Default |
|----------|-------------|---------|
| `SRQL_API_KEY` | Static API key that clients must send via `X-API-Key`. | unset |
| `SRQL_API_KEY_KV_KEY` | Datasvc KV key that contains the API key secret (takes precedence over `SRQL_API_KEY`). | unset |

Usage guidelines:

1. **Static secret (dev/lab):** set `SRQL_API_KEY` in the deployment (Helm values, `docker-compose`, or systemd env file). Clients send `X-API-Key: <value>`.
2. **Managed secret (prod):** create a KV entry (for example `nats kv put config/srql-api-key '<secret>'`) and set `SRQL_API_KEY_KV_KEY=config/srql-api-key`. SRQL will:
   - Resolve `KV_ADDRESS`, TLS cert paths, and SPIFFE IDs just like every other datasvc client.
   - Fail startup if the key does not exist or is malformed (empty/non UTF-8).
   - Watch the key for updates, hot-reloading the header value without restarting the pod.

When `SRQL_API_KEY`/`SRQL_API_KEY_KV_KEY` are both absent, the service logs `SRQL_API_KEY not set; API key authentication disabled` and accepts any request forwarded by the ingress. Keep the ingress locked down (JWT, mTLS, trusted IP ranges) if you ever run SRQL in this mode.

### Rotating Keys via Datasvc

1. Put the new secret into the same KV bucket:
   ```bash
   # Replace with your datasvc context
   nats kv put config/srql-api-key 'srql-prod-2025-02'
   ```
2. SRQL automatically logs `stored API key updated` once the watcher fires. You can confirm with `kubectl logs deploy/serviceradar-srql -n demo | grep 'api key'`.
3. Update any client that is still using the old key; no service restart is required.

## Rate Limiting

SRQL now caps request throughput with a fixed window limiter. The defaults (120 requests every 60 seconds) protect against brute-force attempts when an API key leaks but can be tuned per environment.

| Variable | Description | Default |
|----------|-------------|---------|
| `SRQL_RATE_LIMIT_MAX` | Maximum number of requests allowed per window. | `120` |
| `SRQL_RATE_LIMIT_WINDOW_SECS` | Window size in seconds before tokens reset. | `60` |

Implementation details:
- The limiter uses a semaphore that refills every window. Requests above the threshold block until the next refill, so clients will see longer HTTP latencies instead of immediate `429`s.
- Set `SRQL_RATE_LIMIT_MAX` higher if you front SRQL with a bursty gateway (e.g., GraphQL explorers) or lower during incident response to dampen attack traffic.

## Deployment Checklist

1. **Ingress TLS:** Keep the edge proxy (Caddy/Ingress) terminating TLS in front of SRQL; the service itself only speaks plain HTTP.
2. **Datasvc connectivity:** When using KV-backed keys, ensure the pod has:
   - `KV_ADDRESS`, `KV_SERVER_SPIFFE_ID`, and the mTLS cert volume (see the [KV configuration guide](./kv-configuration.md)).
   - Network access to the datasvc endpoint.
3. **Environment:** Set the new variables in your manifest:
   ```yaml title="k8s snippet"
   env:
     - name: SRQL_API_KEY_KV_KEY
       value: config/srql-api-key
     - name: SRQL_RATE_LIMIT_MAX
       value: "300"
     - name: SRQL_RATE_LIMIT_WINDOW_SECS
       value: "30"
   ```
4. **Verification:** After rollout:
   - Call `/healthz` to confirm the pod is up.
   - Issue a test query with the new header: `curl -H "X-API-Key: $KEY" https://<host>/api/query ...`.
   - Inspect logs for `api key watcher` messages and ensure no `Auth` errors appear for legitimate clients.
5. **Client handoff:** Share the header name/value, and remind teams that missing or wrong keys now yield HTTP 401s.

Following this checklist keeps the SRQL surface area aligned with the rest of the platform: TLS at the ingress, dynamic secrets out of datasvc, and built-in rate limiting to absorb brute-force attempts.
