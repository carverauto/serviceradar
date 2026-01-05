# Sync Service Integrations - Design

## Overview

This document defines the onboarding + runtime architecture for sync services, including multi-tenant configuration delivery, mTLS identity classification, and the agent/agent-gateway pipeline for device updates routed through DIRE.

## Current Architecture

```
┌─────────────────┐     ┌──────────────┐     ┌─────────────┐
│ IntegrationSource│────▶│ datasvc KV   │◀────│ Sync Service│
│ (Ash Resource)  │     │              │     │ (Go)        │
└─────────────────┘     └──────────────┘     └─────────────┘
                              │
                              ▼
                        ┌─────────────┐
                        │ Agent       │
                        │ (sweep.json)│
                        └─────────────┘
```

Problems:
1. Edge agents can't access KV (no network path)
2. Sync services appear implicitly, no onboarding
3. Sync is not multi-tenant aware
4. Device updates bypass agent/agent-gateway and DIRE

## Proposed Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                         Platform Sync                         │
│  - mTLS Hello + GetConfig                                     │
│  - Per-tenant sync loops                                      │
└──────────────────────────────────────────────────────────────┘
                  │                          │
                  │ (mTLS)                   │ (mTLS)
                  ▼                          ▼
        ┌─────────────────┐        ┌─────────────────────┐
        │ Agent Gateway    │        │ Tenant Agent/GW     │
        │ (platform)       │        │ (edge)              │
        └─────────────────┘        └─────────────────────┘
                  │                          │
                  ▼                          ▼
            ┌──────────┐                ┌──────────┐
            │ Core-ELX │                │ Core-ELX │
            └──────────┘                └──────────┘
                  │                          │
                  ▼                          ▼
                ┌────────────────────────────────────────┐
                │                 DIRE                   │
                └────────────────────────────────────────┘
                  │
                  ▼
┌──────────────────────────────────────────────────────────────┐
│                         CNPG (tenant schemas)                │
│  - integration_sources                                       │
│  - sync_services                                             │
│  - discovered_devices (optional staging)                     │
│  - ocsf_devices/device_identifiers (canonical)               │
└──────────────────────────────────────────────────────────────┘
```

## Key Components

### 0. Identity Classification (mTLS vs SPIFFE)

- **SPIFFE SAN present**: treated as platform identity (in-cluster), component type
  is derived from SPIFFE (`agent`, `sync`, etc.) and must be authorized by the
  receiving service.
- **SPIFFE SAN missing**: treated as tenant edge identity (mTLS-only). Tenant
  slug, partition, and component_id are derived from CN and component type is
  unspecified. Authorization relies on component_id + tenant_id scoping.
- **Reserved platform slug**: platform tenant uses a reserved slug (default:
  `platform`), allowing platform identities to be recognized even when running
  with non-SPIFFE mTLS outside the cluster.
- **Zero-trust**: tenant_id is derived solely from the mTLS certificate chain
  and CN/SPIFFE fields; client-supplied tenant identifiers are ignored.

### 1. SyncService Ash Resource

Track onboarded sync services, including platform vs edge classification:

```elixir
defmodule ServiceRadar.Integrations.SyncService do
  use Ash.Resource

  attributes do
    uuid_primary_key :id
    attribute :name, :string
    attribute :service_type, :atom  # :saas, :on_prem
    attribute :endpoint, :string
    attribute :status, :atom  # :online, :offline, :degraded
    attribute :is_platform_sync, :boolean
    attribute :capabilities, {:array, :string}
    attribute :last_heartbeat_at, :utc_datetime
    attribute :tenant_id, :uuid
  end
end
```

### 2. Integration Source Enhancement

Add sync_service_id to IntegrationSource:

```elixir
attribute :sync_service_id, :uuid do
  description "Which sync service processes this integration"
end

relationships do
  belongs_to :sync_service, ServiceRadar.Integrations.SyncService
end
```

### 3. Sync Runtime Config Delivery

- Sync services authenticate via mTLS and call Hello + GetConfig.
- Platform sync receives a per-tenant config bundle; edge sync receives only its tenant config.
- Ash PubSub notifications prompt sync to refresh config.

### 4. Device Update Ingestion + DIRE

- Sync sends device updates to agent or agent-gateway over gRPC.
- Agent-gateway validates tenant scope from mTLS identity.
- Core-elx routes updates through DIRE and persists canonical records in tenant schema.
- Optional discovered_devices staging can be retained for sweep config generation or audit.

### 5. Results Streaming + Chunking

- Sync pushes results to agent-gateway using StreamStatus (client streaming) instead of poller pulls.
- Payload chunking reuses the existing ResultsChunk semantics (indices, totals, sequence, timestamps).
- Results are chunked to stay under gRPC max message sizes (default 4MB; current sync chunking targets ~1MB).

### 6. Platform Bootstrap Enhancement

- Platform bootstrap creates a random platform tenant UUID (non-nil).
- Platform service certs (including sync) include stable platform identifiers.
- Platform sync auto-onboards as a SyncService record.

## Data Flows

### Sync Service Bootstrapping

1. Onboarding generates a minimal sync config file (gateway address, cert paths, identity)
2. Sync service connects to agent-gateway with mTLS
3. Hello handshake identifies service class (platform vs tenant)
4. GetConfig returns integration configs (per tenant)
5. Sync caches configs and starts per-tenant loops

### Device Discovery Flow

1. User creates IntegrationSource with sync_service_id
2. Sync polls integration (Armis/NetBox/Faker)
3. Sync sends discovered devices via agent pipeline
4. Core-elx passes updates through DIRE
5. Canonical device records are written to tenant schema
6. Agent GetConfig includes sweep targets derived from stored device data

## Proto Changes

Reuse the existing AgentGatewayService StreamStatus RPC for sync device updates, with ResultsChunk-compatible chunk metadata.

Enhance AgentConfigResponse:

```protobuf
message AgentConfigResponse {
  // existing fields...
  SweepConfig sweep = 10;
}

message SweepConfig {
  repeated string networks = 1;
  repeated DeviceTarget device_targets = 2;
  repeated string sweep_modes = 3;
  int32 sweep_interval_sec = 4;
}
```

## Migration Strategy

1. Add SyncService + discovered_devices resources and migrations
2. Extend agent-gateway protocol for sync Hello/GetConfig and device updates
3. Update sync service to use agent-gateway config and remove KV
4. Route sync updates through DIRE and verify tenant schema writes
5. Adjust bootstrap to generate platform tenant UUID + platform service certs
6. Deprecate KV-based sweep.json in favor of GetConfig sweep payloads
