---
sidebar_position: 1
title: ServiceRadar Introduction
---

# ServiceRadar Introduction

ServiceRadar is a distributed network monitoring system designed for infrastructure and services in hard-to-reach places or constrained environments. It provides real-time monitoring of internal services with cloud-based alerting capabilities, ensuring you stay informed even during network or power outages.

## What is ServiceRadar?

ServiceRadar offers:
- Real-time monitoring of internal services
- Cloud-based alerting capabilities
- Continuous monitoring during network or power outages
- Distributed architecture for scalability and reliability
- SNMP integration for network device monitoring
- Specialized monitoring for specific node types (e.g., Dusk Network)
- Secure communication with mTLS support
- Modern web UI with dashboard visualization
- API key authentication for internal communications

:::tip What you'll need
- Linux-based system (Ubuntu/Debian recommended)
- Root or sudo access
- Basic understanding of network services
- Target services to monitor
  :::

## Key Components

ServiceRadar consists of four main components:

1. **Agent** - Runs on monitored hosts, provides service status through gRPC
2. **Poller** - Coordinates monitoring activities, can run anywhere in your network
3. **Core Service** - Receives reports from pollers, provides API, and sends alerts
4. **Web UI** - Provides a modern dashboard interface with Nginx as a reverse proxy

```mermaid
graph TD
    subgraph "User Access"
        Browser[Web Browser]
    end

    subgraph "Service Layer"
        WebUI[Web UI<br>:80/nginx]
        CoreAPI[Core Service<br>:8090/:50052]
        WebUI -->|API calls<br>w/key auth| CoreAPI
        Browser -->|HTTP/HTTPS| WebUI
    end

    subgraph "Monitoring Layer"
        Poller1[Poller 1<br>:50053]
        Poller2[Poller 2<br>:50053]
        CoreAPI ---|gRPC<br>bidirectional| Poller1
        CoreAPI ---|gRPC<br>bidirectional| Poller2
    end

    subgraph "Target Infrastructure"
        Agent1[Agent 1<br>:50051]
        Agent2[Agent 2<br>:50051]
        Agent3[Agent 3<br>:50051]
        
        Poller1 ---|gRPC<br>checks| Agent1
        Poller1 ---|gRPC<br>checks| Agent2
        Poller2 ---|gRPC<br>checks| Agent3
        
        Agent1 --- Service1[Services<br>Processes<br>Ports]
        Agent2 --- Service2[Services<br>Processes<br>Ports]
        Agent3 --- Service3[Services<br>Processes<br>Ports]
    end

    subgraph "Alerting"
        CoreAPI -->|Webhooks| Discord[Discord]
        CoreAPI -->|Webhooks| Other[Other<br>Services]
    end

    style Browser fill:#f9f,stroke:#333,stroke-width:1px
    style WebUI fill:#b9c,stroke:#333,stroke-width:1px
    style CoreAPI fill:#9bc,stroke:#333,stroke-width:2px
    style Poller1 fill:#adb,stroke:#333,stroke-width:1px
    style Poller2 fill:#adb,stroke:#333,stroke-width:1px
    style Agent1 fill:#fd9,stroke:#333,stroke-width:1px
    style Agent2 fill:#fd9,stroke:#333,stroke-width:1px
    style Agent3 fill:#fd9,stroke:#333,stroke-width:1px
    style Discord fill:#c9d,stroke:#333,stroke-width:1px
    style Other fill:#c9d,stroke:#333,stroke-width:1px
```

## Getting Started

Navigate through our documentation to get ServiceRadar up and running:

1. **[Installation Guide](./installation.md)** - Install ServiceRadar components
2. **[Configuration Basics](./configuration.md)** - Configure your ServiceRadar deployment
3. **[TLS Security](./tls-security.md)** - Secure your ServiceRadar communications
4. **[Web UI Configuration](./web-ui.md)** - Set up the web interface and dashboard

Or jump straight to the [Installation Guide](./installation.md) to get started with ServiceRadar.