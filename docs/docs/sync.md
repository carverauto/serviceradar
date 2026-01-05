---
sidebar_position: 9
title: Sync Service Configuration
---

# Sync Service Configuration

The ServiceRadar Sync service integrates external inventories (NetBox, Armis, etc.) with the platform. It is a push-first runtime that fetches devices from configured sources and streams updates through the agent-gateway to core, where DIRE reconciles them into canonical device records.

## Overview

The Sync service:
- Fetches data from external systems like CMDB, IPAM, or security tools.
- Pushes device updates to the agent-gateway over gRPC using chunked `StreamStatus`.
- Receives its runtime configuration from Core via `GetConfig` (per tenant).
- Runs with minimal on-disk bootstrap config; the rest is delivered dynamically.
- Supports platform and edge deployments with mTLS-based tenant isolation.

## Architecture

```mermaid
graph TD
    UI[Web UI<br/>Integrations] --> Core[(Core / Ash)]
    Core -->|GetConfig| Gateway[Agent-Gateway]

    Sync[Sync Service] -->|Hello + GetConfig| Gateway
    Sync -->|StreamStatus (ResultsChunk payloads)| Gateway

    Gateway --> Core
    Core --> DIRE[DIRE]
    DIRE --> Inventory[(Device Inventory)]
```

## Bootstrap Configuration (Minimal)

The Sync service boots from a minimal JSON config and fetches the full integration configuration at runtime.

```json
{
  "agent_id": "sync-edge-1",
  "listen_addr": ":50058",
  "gateway_addr": "agent-gateway:50052",
  "gateway_security": {
    "mode": "mtls",
    "cert_dir": "/etc/serviceradar/certs",
    "server_name": "agent-gateway",
    "role": "sync",
    "tls": {
      "cert_file": "component.pem",
      "key_file": "component-key.pem",
      "ca_file": "ca-chain.pem",
      "client_ca_file": "ca-chain.pem"
    }
  }
}
```

### Bootstrap Options

| Option | Description | Required |
|--------|-------------|----------|
| `agent_id` | Stable sync service identifier (matches onboarding component ID) | Yes |
| `listen_addr` | Sync gRPC listen address | Yes |
| `gateway_addr` | Agent-gateway gRPC endpoint | Yes |
| `gateway_security` | mTLS configuration for gateway connection | Yes |

All integration sources, credentials, and schedules are delivered via `GetConfig` after the sync service enrolls.

## Dynamic Configuration (GetConfig)

On startup, the sync service:
1. Calls `AgentGatewayService.Hello` to enroll (tenant is derived from mTLS).
2. Calls `AgentGatewayService.GetConfig` to fetch integration sources.
3. Polls for config updates on the interval provided by Core.

Integration sources are created in the UI under **Integrations -> New Source**. Each tenant only sees its own sources. Platform sync services receive a multi-tenant view that includes all tenants.

## Results Streaming API

The sync service does **not** serve pull APIs (`GetResults`/`StreamResults` are deprecated). It pushes device updates using `AgentGatewayService.StreamStatus` with ResultsChunk-compatible semantics:

- Each `GatewayStatusChunk` carries one `GatewayServiceStatus` with:
  - `service_type = "sync"`
  - `source = "results"`
  - `message = JSON array of DeviceUpdate`
- Chunks are size-limited to ~3MB to stay under the default 4MB gRPC limit.
- The chunk metadata (`chunk_index`, `total_chunks`, `is_final`) matches ResultsChunk semantics.

### ResultsChunk Compatibility

Sync uses the ResultsChunk fields to drive chunk ordering and sequencing, even though it streams via `GatewayStatusChunk`:

| Field | Meaning |
|-------|---------|
| `data` | JSON array of `DeviceUpdate` records |
| `is_final` | Marks the last chunk in a stream |
| `chunk_index` | Zero-based chunk order |
| `total_chunks` | Total number of chunks in the stream |
| `current_sequence` | Sequence identifier for this batch |
| `timestamp` | Unix timestamp for the batch |

`ResultsRequest` is deprecated for sync; the sync service does not implement pull-based results.

### gRPC Size Limits

Default gRPC max message size is 4MB. To override (server-side):

- `GRPC_MAX_RECV_MSG_SIZE` (bytes or suffix like `8MB`)
- `GRPC_MAX_SEND_MSG_SIZE`

The sync service chunking logic targets 3MB to avoid hitting limits even when metadata expands.

## Multi-Tenant Behavior

- **Platform Sync**: Uses platform mTLS credentials and receives sources for all tenants. Sources are keyed as `<tenant_slug>/<source_name>` in the config payload.
- **Edge Sync**: Uses tenant-specific mTLS credentials and only receives that tenant's sources.
- Tenant identity is derived from mTLS; tenant IDs in payloads are trusted from mTLS only.

## Troubleshooting

- **No config returned**: Verify the sync service can reach agent-gateway and the cert identity is valid.
- **Tenant mismatch**: Ensure the sync service uses the correct tenant certificate (edge) or platform certificate (platform).
- **gRPC size errors**: Confirm chunk size stays under ~3MB, or raise gRPC max message sizes via environment variables.
