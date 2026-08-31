---
sidebar_position: 1
title: ServiceRadar Introduction
---

# ServiceRadar Introduction

ServiceRadar is an IT operations and network management platform with built-in
observability and security analytics. It is designed to monitor infrastructure and
services in hard-to-reach places and constrained environments, with cloud-based alerting
so you stay informed even during network or power outages.

## What is ServiceRadar?

ServiceRadar brings four capabilities together in one platform:

- **Network management** — discover, map, and monitor your network with SNMP, NetFlow,
  BGP, network sweeps, and live topology.
- **IT operations** — track devices, services, and infrastructure health with a
  distributed, agent-based architecture built for the edge.
- **Observability** — collect metrics, traces, and logs with OpenTelemetry and query
  everything with SRQL, ServiceRadar's unified query language.
- **Security analytics** — ingest syslog, runtime security events, and vulnerability
  scans into one normalized, alertable event store.

:::tip What you'll need
- Linux-based system (Ubuntu/Debian recommended)
- Root or sudo access
- Basic understanding of network services
- Target services to monitor
:::

## Key Components

ServiceRadar consists of several main components:

1. **Agent** - Runs on monitored hosts, collects data, and pushes results over gRPC
2. **Agent-Gateway** - Edge ingress for agent and collector traffic
3. **Core Service (core-elx)** - Control plane for ingestion, APIs, and alerts
4. **Web UI (web-ng)** - Phoenix LiveView dashboard with SRQL embedded via Rustler/NIF
5. **CNPG + TimescaleDB** - System of record for telemetry and inventory
6. **NATS JetStream** - Messaging backbone for platform services

For a detailed explanation of the architecture, see the [Architecture](./architecture.md)
page.

## Security Features

ServiceRadar is designed with security in mind:

1. **Automated service and agent identity** - Platform TLS and agent enrollment
   credentials are provisioned for you on Cloud and in standard Helm/Compose
   installs; day-1 agent onboarding does not require hand-built CAs
2. **User Authentication** - Password login, Direct SSO (OIDC/SAML), or gateway-proxied
   JWT auth
3. **Session Management** - Secure, expirable sessions for the web UI and API access
4. **Role-Based Access** - Instance-scoped roles and permissions for administrative actions

For operator SSO and RBAC, see [Authentication](./auth-configuration.md),
[Group Permission Mapping](./group-permission-mapping.md), and
[Roles & Permissions](./rbac-and-roles.md). Advanced custom-CA scenarios remain in
[TLS & mTLS](./tls-security.md).

## Getting Started

Work through the documentation in roughly this order:

### Deploy
1. **[Cloud Quickstart](./cloud-quickstart.md)** - Hosted SaaS runbook (agents, SSO, collectors, RBAC)
2. **[Self-hosted Quickstart](./quickstart.md)** - Docker/Helm path when you run the stack yourself
3. **[Docker Compose](./docker-setup.md)** - Complete Docker deployment with automatic
   configuration
4. **[Kubernetes (Helm)](./helm-configuration.md)** - Production-style deployments
5. **[Authentication](./auth-configuration.md)** - Users, sessions, and SSO integration
6. **[Outbound Mail](./outbound-mail.md)** - SMTP for reports, alert email, and account mail

### Get data in
7. **[Device Configuration](./device-configuration.md)** - Configure network devices for
   SNMP, Syslog, and trap collection
8. **[Data Pipeline](./data-pipeline.md)** - JetStream consumers and CNPG persistence

### Query and analyze
9. **[SRQL Tutorial](./srql-tutorial.md)** - Learn ServiceRadar's query language
10. **[Rule Builder](./rule-builder.md)** - Turn queries into alerts
11. **[Notifications Quickstart](./notification-quickstart.md)** - Page Discord, Slack, or email when an alert fires

### Go deeper
12. **[Architecture](./architecture.md)** - Understand the system architecture
13. **[Edge Model](./edge-model.md)** - Agent lifecycle, config flow, and command bus
14. **[Wasm Plugins](./wasm-plugins.md)** - Sandboxed plugin system and SDKs

**Recommended**: Start with the [Cloud Quickstart](./cloud-quickstart.md) for hosted
SaaS, or the [Self-hosted Quickstart](./quickstart.md) when you install the stack.
