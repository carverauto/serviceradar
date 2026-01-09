---
sidebar_position: 9
title: Sync Runtime
---

# Sync Runtime (Embedded in Agent)

ServiceRadar sync is embedded in `serviceradar-agent`. It fetches device
inventory from external systems (NetBox, Armis, etc.) and streams device updates
through the agent-gateway to core, where DIRE reconciles them into canonical
device records.

## Overview

The embedded sync runtime:
- Fetches data from external systems like CMDB, IPAM, or security tools.
- Pushes device updates to the agent-gateway over gRPC using chunked
  `StreamStatus`.
- Receives its runtime configuration from Core via `GetConfig` (per tenant).
- Runs with the agent's minimal bootstrap config; all integration data is
  delivered dynamically.

## Architecture

```mermaid
graph TD
    UI[Web UI<br/>Integrations] --> Core[(Core / Ash)]
    Core -->|GetConfig| Gateway[Agent-Gateway]

    Agent[Agent + Embedded Sync] -->|Hello + GetConfig| Gateway
    Agent -->|StreamStatus (ResultsChunk payloads)| Gateway

    Gateway --> Core
    Core --> DIRE[DIRE]
    DIRE --> Inventory[(Device Inventory)]
```

## Configuration Delivery

Integration sources are created in the UI under **Integrations -> New Source**.
Each tenant only sees its own sources, and the agent receives them over
`GetConfig`. The embedded sync runtime stores this configuration in memory and
reloads it when updates arrive.

### Example Integration Payload (JSON)

```json
{
  "poll_interval": "10m",
  "sources": {
    "armis_prod": {
      "type": "armis",
      "endpoint": "https://my-armis-instance.armis.com",
      "credentials": {
        "secret_key": "your-armis-api-secret-key"
      }
    },
    "netbox_dc1": {
      "type": "netbox",
      "endpoint": "https://netbox.example.com",
      "credentials": {
        "api_token": "your-netbox-api-token"
      }
    }
  }
}
```

## Results Streaming API

The embedded sync runtime does **not** serve pull APIs (`GetResults` or
`StreamResults`). It pushes device updates using
`AgentGatewayService.StreamStatus` with ResultsChunk-compatible semantics:

- Each `GatewayStatusChunk` carries one `GatewayServiceStatus` with:
  - `service_type = "sync"`
  - `source = "results"`
  - `message = JSON array of DeviceUpdate`
- Chunks are size-limited to roughly 3MB to stay under default gRPC limits.
- Chunk metadata (`chunk_index`, `total_chunks`, `is_final`) matches
  ResultsChunk semantics.

### gRPC Size Limits

Default gRPC max message size is 4MB. To override (server-side):

- `GRPC_MAX_RECV_MSG_SIZE` (bytes or suffix like `8MB`)
- `GRPC_MAX_SEND_MSG_SIZE`

## Sync Ingestion Tuning Matrix

Use these starting points when the embedded sync runtime is streaming large device inventories into core-elx. The goal is to smooth bursty chunk delivery, keep CNPG connection usage predictable, and avoid queue timeouts.

**Connection budget rule of thumb**
- Keep total core-elx pool connections at ~60% of CNPG `max_connections`. Reserve the remaining ~40% for web-ng, datasvc, migrations, and ad-hoc tooling.
- Formula: `pool_size_per_core = floor(max_connections * 0.6 / core_replicas)`.

**Pool sizing examples (per core-elx pod)**

| CNPG max_connections | Core replicas | Pool size per pod | Total core connections |
| --- | --- | --- | --- |
| 500 | 4 | 75 | 300 |
| 500 | 8 | 38 | 304 |
| 1000 | 6 | 100 | 600 |
| 1000 | 10 | 60 | 600 |
| 2000 | 12 | 100 | 1200 |
| 2000 | 20 | 60 | 1200 |

**Ingestion knobs by workload size**

| Workload | POOL_SIZE | DATABASE_QUEUE_TARGET_MS / INTERVAL_MS | SYNC_INGESTOR_COALESCE_MS | SYNC_INGESTOR_QUEUE_MAX_CHUNKS | SYNC_INGESTOR_MAX_INFLIGHT | SYNC_INGESTOR_BATCH_CONCURRENCY |
| --- | --- | --- | --- | --- | --- | --- |
| Small (single tenant, <= 50k devices) | 40 | 2000 / 2000 | 250 | 10 | 2 | 2 |
| Medium (5-10 tenants, <= 500k devices) | 60-80 | 3000 / 3000 | 250-500 | 10-20 | 3-4 | 2-4 |
| Large (10-20 tenants, >= 1M devices) | 80-120 | 5000 / 5000 | 500 | 20-40 | 4-6 | 3-6 |

**Adjustments**
- If you see `queue_timeout` errors, either raise `POOL_SIZE` (if CNPG can accept more) or raise `DATABASE_QUEUE_TARGET_MS`/`DATABASE_QUEUE_INTERVAL_MS` so requests wait longer.
- If chunk bursts are spiky, raise `SYNC_INGESTOR_COALESCE_MS` or `SYNC_INGESTOR_QUEUE_MAX_CHUNKS` to merge more payloads before hitting the DB.
- If CNPG CPU or locks spike, lower `SYNC_INGESTOR_BATCH_CONCURRENCY` before reducing `POOL_SIZE`.

## Migration from Standalone Sync

If you previously deployed `serviceradar-sync` as a standalone service, migrate
to the embedded sync runtime inside `serviceradar-agent`:

1. Install or upgrade an agent in the tenant network and confirm it registers
   with agent-gateway.
2. Remove the standalone sync process (systemd/compose/helm) and revoke any
   sync-specific certificates.
3. Recreate integration sources in the UI (Integrations -> New Source), or
   verify existing sources are assigned to the correct agent.
4. Ensure only agent-gateway gRPC traffic is allowed outbound (port 50052).
5. Watch agent logs for `GetConfig` fetches and `StreamStatus` pushes.

Standalone `sync.json` files and KV/datasvc dependencies are no longer used.

## Multi-Tenant Behavior

- Tenant identity is derived from the agent's mTLS identity.
- The agent only receives sources scoped to its tenant.
- Tenant IDs in payloads are trusted only when derived from mTLS.

## Troubleshooting

- **No config returned**: Verify the agent can reach agent-gateway and the cert
  identity is valid.
- **Tenant mismatch**: Ensure the agent uses the correct tenant certificate.
- **gRPC size errors**: Confirm chunk size stays under ~3MB, or raise gRPC max
  message sizes via environment variables.
