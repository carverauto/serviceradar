---
sidebar_position: 6
title: Architecture
---

# Architecture

ServiceRadar is a distributed monitoring platform with an Elixir/ERTS control plane and a single Go edge agent. The agent runs collectors and sandboxed Wasm plugins, then streams results to the platform over mTLS gRPC.

This page stays high-level on purpose. It aims to give you the correct mental model before you dive into specific protocol or deployment docs.

## High-Level System Diagram

```mermaid
flowchart TB
  User([User / Browser])

  subgraph Core["Core Platform (Kubernetes or Docker Compose)"]
    Ingress["Edge proxy (Ingress/Caddy)"]
    Web["web-ng (Phoenix LiveView)<br/>SRQL embedded (Rustler/NIF)"]
    CoreElx["core-elx (Elixir control plane)"]
    GW["agent-gateway (Elixir)"]

    NATS["NATS JetStream"]
    Zen["zen-consumer"]
    Promote["log-promotion"]
    Writer["db-event-writer"]

    DB["CNPG (Postgres + Timescale + AGE)"]
  end

  subgraph Edge["Edge Site / Monitored Network"]
    Agent["serviceradar-agent (Go)<br/>collectors + embedded engines + wazero plugins"]
  end

  User -->|HTTPS| Ingress --> Web

  Agent <-->|mTLS gRPC<br/>streaming, chunking, control stream| GW
  GW <-->|mTLS ERTS/RPC/PubSub| CoreElx
  Web <-->|mTLS ERTS/RPC/PubSub| CoreElx

  %% Bulk ingestion
  NATS --> Zen --> NATS
  NATS --> Promote --> NATS
  NATS --> Writer --> DB

  CoreElx --> DB
  Web --> DB
```

## Control Plane (ERTS Cluster)

The core platform is an ERTS cluster of:

- `core-elx`: APIs, orchestration, ingestion, and persistence
- `web-ng`: UI and HTTP API surface; SRQL is embedded via Rustler/NIF
- `agent-gateway`: edge ingress (agent connectivity and ingestion)

These components communicate internally over mTLS-secured Erlang distribution (ERTS), using RPC and PubSub semantics.

## Edge Agent

`serviceradar-agent` is the single edge runtime. It connects outbound to `agent-gateway` and:

- runs built-in collectors and engines (for example sync integrations, SNMP polling, discovery/mapping, mDNS)
- executes sandboxed Wasm plugins using `wazero`
- streams results using unary and streaming gRPC (chunked payloads for large datasets)
- participates in a bidirectional control stream for control-plane signaling

See [Edge Model](./edge-model.md).

## Bulk Telemetry Pipeline (NATS JetStream)

Collectors publish bulk telemetry into JetStream (commonly the `events` stream). The platform currently runs three consumers on `events`:

- `zen-consumer` (normalization)
- `log-promotion` (promotion into OCSF-style events)
- `db-event-writer` (persistence into CNPG)

See [Data Pipeline](./data-pipeline.md).

## Identity And TLS

- Everything is mTLS by default.
- SPIFFE/SPIRE is supported in Kubernetes deployments.
- Docker Compose uses non-SPIFFE mTLS bootstrapping (cert generation + distribution via volumes).

See [TLS / mTLS](./tls-security.md).
