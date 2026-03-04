---
sidebar_position: 1
title: ServiceRadar Introduction
---

# ServiceRadar Introduction

ServiceRadar is a distributed network monitoring system designed for infrastructure and services in hard-to-reach places or constrained environments. It provides real-time monitoring of internal services with cloud-based alerting capabilities, ensuring you stay informed even during network or power outages.

## What is ServiceRadar?

ServiceRadar offers:
- Real-time monitoring of internal services
- Distributed architecture for scalability and reliability
- SNMP integration for network device monitoring
- Secure communication with mTLS
- Modern web UI with dashboard visualization
- SRQL key:value query language for unified analytics across devices, events, and telemetry
- User authentication with JWT-based sessions
- External system integration via embedded sync runtime (agent)

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
3. **Core Service (core-elx)** - Control plane for DIRE, ingestion, APIs, and alerts
4. **Web UI (web-ng)** - Phoenix LiveView dashboard with SRQL embedded via Rustler/NIF
5. **CNPG + TimescaleDB** - System of record for telemetry and inventory
6. **NATS JetStream** - Messaging backbone for platform services

For a detailed explanation of the architecture, please see the [Architecture](./architecture.md) page.

## Security Features

ServiceRadar is designed with security in mind:

1. **mTLS Authentication** - Secure communication between components using mutual TLS
2. **User Authentication** - Password login, Direct SSO (OIDC/SAML), or gateway-proxied JWT auth
3. **Session Management** - Secure, expirable sessions for the web UI and API access
4. **Role-Based Access** - Instance-scoped roles and permissions for administrative actions

For more details, see the [TLS Security](./tls-security.md) and [Authentication Configuration](./auth-configuration.md) documentation.

## Getting Started

Navigate through our documentation to get ServiceRadar up and running:

### Quick Start with Docker
- **[Docker Setup Guide](./docker-setup.md)** - Complete Docker deployment guide with automatic configuration
- **[Device Configuration](./device-configuration.md)** - Configure network devices for SNMP, Syslog, and trap collection

### Deploy + Secure
1. **[Kubernetes (Helm)](./helm-configuration.md)** - Production-style deployments
2. **[TLS / mTLS](./tls-security.md)** - Secure service-to-service and agent connectivity
3. **[Authentication](./auth-configuration.md)** - Users, sessions, and SSO integration

### Advanced Topics
4. **[Architecture](./architecture.md)** - Understand the system architecture
5. **[Edge Model](./edge-model.md)** - Agent lifecycle, config flow, and command bus
6. **[Data Pipeline](./data-pipeline.md)** - JetStream consumers and CNPG persistence
7. **[Tools Pod](./tools.md)** - Preconfigured operational CLI environment
8. **[CNPG PG18 Upgrade](./cnpg-pg18-upgrade-and-search-policy.md)** - Upgrade runbook, validation, and BM25 extension policy
9. **[Wasm Plugins](./wasm-plugins.md)** - Sandboxed plugin system and SDKs

**Recommended**: Start with the [Docker Setup Guide](./docker-setup.md) for the fastest and most reliable deployment experience.
