# Sync Service Integrations - Design

## Overview

This document defines the onboarding + runtime architecture for sync capability embedded in the agent. Sync no longer runs as a standalone service; each tenant deploys `serviceradar-agent`, which handles integration config delivery, discovery loops, and device updates routed through the agent/agent-gateway pipeline and DIRE.

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
1. Standalone sync adds operational overhead and separate onboarding.
2. Edge agents can't access KV (no network path).
3. Sync is not multi-tenant aware.
4. Device updates bypass agent/agent-gateway and DIRE.

## Proposed Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                    Tenant Agent (sync)                       │
│  - mTLS Hello + GetConfig                                     │
│  - Tenant-scoped sync loops                                   │
└──────────────────────────────────────────────────────────────┘
                  │
                  │ (mTLS)
                  ▼
        ┌─────────────────┐
        │ Agent Gateway    │
        │ (platform)       │
        └─────────────────┘
                  │
                  ▼
            ┌──────────┐
            │ Core-ELX │
            └──────────┘
                  │
                  ▼
                ┌────────────────────────────────────────┐
                │                 DIRE                   │
                └────────────────────────────────────────┘
                  │
                  ▼
┌──────────────────────────────────────────────────────────────┐
│                         CNPG (tenant schemas)                │
│  - integration_sources                                       │
│  - ocsf_devices/device_identifiers (canonical)               │
└──────────────────────────────────────────────────────────────┘
```

## Key Components

### 0. Identity Classification (mTLS vs SPIFFE)

- **SPIFFE SAN present**: treated as platform identity (in-cluster), component type
  is derived from SPIFFE (`agent`, `gateway`, etc.) and must be authorized by the
  receiving service.
- **SPIFFE SAN missing**: treated as tenant edge identity (mTLS-only). Tenant
  slug, partition, and component_id are derived from CN. Authorization relies on
  component_id + tenant_id scoping.
- **Reserved platform slug**: platform tenant uses a reserved slug (default:
  `platform`), allowing platform identities to be recognized even when running
  with non-SPIFFE mTLS outside the cluster.
- **Zero-trust**: tenant_id is derived solely from the mTLS certificate chain
  and CN/SPIFFE fields; client-supplied tenant identifiers are ignored.

### 1. Agent Sync Capability

Sync runs inside `serviceradar-agent`. The agent advertises sync capability during
Hello/GetConfig and processes integration sources assigned to it.

### 2. Integration Source Assignment

IntegrationSource records are assigned to an agent (sync runner) rather than a
standalone sync service:

```elixir
attribute :agent_id, :uuid do
  description "Which agent runs this integration"
end

relationships do
  belongs_to :agent, ServiceRadar.Infrastructure.Agent
end
```

### 3. Agent Config Delivery

- Agent authenticates via mTLS and calls Hello + GetConfig.
- GetConfig includes integration sources for the tenant and agent.
- Ash PubSub notifications prompt agent to refresh config.

### 4. Device Update Ingestion + DIRE

- Agent sync sends device updates to agent-gateway over gRPC.
- Agent-gateway validates tenant scope from mTLS identity.
- Core-elx routes updates through DIRE and persists canonical records in tenant schema.

### 5. Results Streaming + Chunking

- Agent sync pushes results to agent-gateway using StreamStatus (client streaming).
- Payload chunking reuses the existing ResultsChunk semantics (indices, totals, sequence, timestamps).
- Results are chunked to stay under gRPC max message sizes (default 4MB; current chunking targets ~1MB).

## Data Flows

### Agent Sync Bootstrapping

1. Onboarding generates a minimal agent config file (gateway address, cert paths, identity).
2. Agent connects to agent-gateway with mTLS.
3. Hello handshake identifies agent capability (including sync).
4. GetConfig returns integration configs scoped to the tenant/agent.
5. Agent caches configs and starts sync loops.

### Device Discovery Flow

1. User creates IntegrationSource assigned to a sync-capable agent.
2. Agent polls integration (Armis/NetBox/Faker).
3. Agent sends discovered devices via agent pipeline.
4. Core-elx passes updates through DIRE.
5. Canonical device records are written to tenant schema.

## Proto Changes

Reuse the existing AgentGatewayService StreamStatus RPC for sync device updates, with ResultsChunk-compatible chunk metadata. No new sync-specific RPCs are introduced.
