---
sidebar_position: 6
title: Architecture
---

# ServiceRadar Architecture

ServiceRadar uses a distributed, multi-layered architecture designed for flexibility, reliability, and security. This page explains how the different components work together to provide robust monitoring capabilities.

## Architecture Overview

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

## Key Components

### Agent (Monitored Host)

The Agent runs on each host you want to monitor and is responsible for:

- Collecting service status information (process status, port availability, etc.)
- Exposing a gRPC service on port 50051 for Pollers to query
- Supporting various checker types (process, port, SNMP, etc.)
- Running with minimal privileges for security

**Technical Details:**
- Written in Go for performance and minimal dependencies
- Uses gRPC for efficient, language-agnostic communication
- Supports dynamic loading of checker plugins
- Can run on constrained hardware with minimal resource usage

### Poller (Monitoring Coordinator)

The Poller coordinates monitoring activities and is responsible for:

- Querying multiple Agents at configurable intervals
- Aggregating status data from Agents
- Reporting status to the Core Service
- Performing direct checks (HTTP, ICMP, etc.)
- Supporting network sweeps and discovery

**Technical Details:**
- Runs on port 50053 for gRPC communications
- Stateless design allows multiple Pollers for high availability
- Configurable polling intervals for different check types
- Supports both pull-based (query) and push-based (events) monitoring

### Core Service (API & Processing)

The Core Service is the central component that:

- Receives and processes reports from Pollers
- Provides an API for the Web UI on port 8090
- Triggers alerts based on configurable thresholds
- Stores historical monitoring data
- Manages webhook notifications

**Technical Details:**
- Exposes a gRPC service on port 50052 for Poller connections
- Provides a RESTful API on port 8090 for the Web UI
- Uses role-based security model
- Implements webhook templating for flexible notifications

### Web UI (User Interface)

The Web UI provides a modern dashboard interface that:

- Visualizes the status of monitored services
- Displays historical performance data
- Provides configuration management
- Securely communicates with the Core Service API

**Technical Details:**
- Built with Next.js in SSR mode for security and performance
- Uses Nginx as a reverse proxy on port 80
- Communicates with the Core Service API using a secure API key
- Supports responsive design for mobile and desktop

## Security Architecture

ServiceRadar implements multiple layers of security:

### mTLS Security

For network communication between components, ServiceRadar supports mutual TLS (mTLS):

```mermaid
graph TB
subgraph "Agent Node"
AG[Agent<br/>Role: Server<br/>:50051]
SNMPCheck[SNMP Checker<br/>:50054]
DuskCheck[Dusk Checker<br/>:50052]
SweepCheck[Network Sweep]

        AG --> SNMPCheck
        AG --> DuskCheck
        AG --> SweepCheck
    end
    
    subgraph "Poller Service"
        PL[Poller<br/>Role: Client+Server<br/>:50053]
    end
    
    subgraph "Core Service"
        CL[Core Service<br/>Role: Server<br/>:50052]
        DB[(Database)]
        API[HTTP API<br/>:8090]
        
        CL --> DB
        CL --> API
    end
    
    %% Client connections from Poller
    PL -->|mTLS Client| AG
    PL -->|mTLS Client| CL
    
    %% Server connections to Poller
    HC1[Health Checks] -->|mTLS Client| PL
    
    classDef server fill:#e1f5fe,stroke:#01579b
    classDef client fill:#f3e5f5,stroke:#4a148c
    classDef dual fill:#fff3e0,stroke:#e65100
    
    class AG,CL server
    class PL dual
    class SNMPCheck,DuskCheck,SweepCheck client
```

### API Authentication

The Web UI communicates with the Core Service using API key authentication:

```mermaid
sequenceDiagram
    participant User as User (Browser)
    participant WebUI as Web UI (Next.js)
    participant API as Core API
    
    User->>WebUI: HTTP Request
    Note over WebUI: Server-side middleware<br>loads API key
    WebUI->>API: Request with API Key
    API->>API: Validate API Key
    API->>WebUI: Response
    WebUI->>User: Rendered UI
```

For details on configuring security, see the [TLS Security](./tls-security.md) documentation.

## Deployment Models

ServiceRadar supports multiple deployment models:

### Standard Deployment

All components installed on separate machines for optimal security and reliability:

```mermaid
graph LR
    Browser[Browser] --> WebServer[Web Server<br/>Web UI + Core]
    WebServer --> PollerServer[Poller Server]
    PollerServer --> AgentServer1[Host 1<br/>Agent]
    PollerServer --> AgentServer2[Host 2<br/>Agent]
    PollerServer --> AgentServerN[Host N<br/>Agent]
```

### Minimal Deployment

For smaller environments, components can be co-located:

```mermaid
graph LR
    Browser[Browser] --> CombinedServer[Combined Server<br/>Web UI + Core + Poller]
    CombinedServer --> AgentServer1[Host 1<br/>Agent]
    CombinedServer --> AgentServer2[Host 2<br/>Agent]
```

### High Availability Deployment

For mission-critical environments:

```mermaid
graph TD
    LB[Load Balancer] --> WebServer1[Web Server 1<br/>Web UI]
    LB --> WebServer2[Web Server 2<br/>Web UI]
    WebServer1 --> CoreServer1[Core Server 1]
    WebServer2 --> CoreServer1
    WebServer1 --> CoreServer2[Core Server 2]
    WebServer2 --> CoreServer2
    CoreServer1 --> Poller1[Poller 1]
    CoreServer2 --> Poller1
    CoreServer1 --> Poller2[Poller 2]
    CoreServer2 --> Poller2
    Poller1 --> Agent1[Agent 1]
    Poller1 --> Agent2[Agent 2]
    Poller2 --> Agent1
    Poller2 --> Agent2
```

## Network Requirements

ServiceRadar uses the following network ports:

| Component | Port | Protocol | Purpose |
|-----------|------|----------|---------|
| Agent | 50051 | gRPC/TCP | Service status queries |
| Poller | 50053 | gRPC/TCP | Health checks |
| Core | 50052 | gRPC/TCP | Poller connections |
| Core | 8090 | HTTP/TCP | API (internal) |
| Web UI | 80/443 | HTTP(S)/TCP | User interface |
| SNMP Checker | 50054 | gRPC/TCP | SNMP status queries |
| Dusk Checker | 50052 | gRPC/TCP | Dusk node monitoring |

For more information on deploying ServiceRadar, see the [Installation Guide](./installation.md).