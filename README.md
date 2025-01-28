# ServiceRadar

[![Release ServiceRadar Packages](https://github.com/mfreeman451/serviceradar/actions/workflows/release.yml/badge.svg)](https://github.com/mfreeman451/serviceradar/actions/workflows/release.yml)
[![lint](https://github.com/mfreeman451/serviceradar/actions/workflows/golangci-lint.yml/badge.svg)](https://github.com/mfreeman451/serviceradar/actions/workflows/golangci-lint.yml)
[![test](https://github.com/mfreeman451/serviceradar/actions/workflows/go-coverage.yml/badge.svg)](https://github.com/mfreeman451/serviceradar/actions/workflows/go-coverage.yml)
<a href="https://cla-assistant.io/mfreeman451/serviceradar"><img src="https://cla-assistant.io/readme/badge/mfreeman451/serviceradar" alt="CLA assistant" /></a>

ServiceRadar is a distributed network monitoring system designed for infrastructure and services in hard to reach places or constrained environments. 
It provides real-time monitoring of internal services, with cloud-based alerting capabilities to ensure you stay informed even during network or power outages.

### Screenshots
<img width="1387" alt="Screenshot 2025-01-24 at 1 56 23 PM" src="https://github.com/user-attachments/assets/c5632d2a-eb66-47dd-908c-bf5e093c2a3e" />
<img width="1393" alt="Screenshot 2025-01-26 at 12 10 58 AM" src="https://github.com/user-attachments/assets/59cb83a7-825e-4724-8d54-1bcc2cedfb7d" />
<img width="1393" alt="Screenshot 2025-01-26 at 12 10 31 AM" src="https://github.com/user-attachments/assets/20c81f10-8fa3-46db-963b-f40d55fb3569" />
<img width="1387" alt="Screenshot 2025-01-24 at 1 57 30 PM" src="https://github.com/user-attachments/assets/a89c4b7e-9909-4d6d-80ee-3613be516d83" />
<img width="1387" alt="Screenshot 2025-01-24 at 1 58 13 PM" src="https://github.com/user-attachments/assets/d6afcd15-7952-4cf3-9132-4142afe6591c" />


### Monitoring a Dusk Node

<img width="1386" alt="Screenshot 2025-01-24 at 1 58 44 PM" src="https://github.com/user-attachments/assets/712b78b0-6c5d-43d6-883c-4e87631830dc" />

https://docs.dusk.network/operator/overview/

### Installation

ServiceRadar can be installed via direct downloads from GitHub releases.

#### Standard Setup (Recommended)
Install these components on your monitored host:
```bash
# Download and install core components
curl -LO https://github.com/mfreeman451/serviceradar/releases/download/1.0.3/serviceradar-agent_1.0.8.deb \
     -O https://github.com/mfreeman451/serviceradar/releases/download/1.0.3/serviceradar-poller_1.0.8.deb

sudo dpkg -i serviceradar-agent_1.0.8.deb serviceradar-poller_1.0.8.deb
```

On a separate machine (recommended) or the same host:
```bash
# Download and install cloud service
curl -LO https://github.com/mfreeman451/serviceradar/releases/download/1.0.3/serviceradar-cloud_1.0.8.deb
sudo dpkg -i serviceradar-cloud_1.0.8.deb
```

#### Optional: Dusk Node Monitoring
If you're running a [Dusk](https://dusk.network/) node and want specialized monitoring:
```bash
curl -LO https://github.com/mfreeman451/serviceradar/releases/download/1.0.8/serviceradar-dusk-checker_1.0.8.deb
sudo dpkg -i serviceradar-dusk-checker_1.0.8.deb
```

#### Distributed Setup
For larger deployments where components run on different hosts:

1. On monitored hosts:
```bash
curl -LO https://github.com/mfreeman451/serviceradar/releases/download/1.0.8/serviceradar-agent_1.0.8.deb
sudo dpkg -i serviceradar-agent_1.0.8.deb
```

2. On monitoring host:
```bash
curl -LO https://github.com/mfreeman451/serviceradar/releases/download/1.0.3/serviceradar-poller_1.0.8.deb
sudo dpkg -i serviceradar-poller_1.0.8.deb
```

3. On cloud host:
```bash
curl -LO https://github.com/mfreeman451/serviceradar/releases/download/1.0.3/serviceradar-cloud_1.0.8.deb
sudo dpkg -i serviceradar-cloud_1.0.8.deb
```

## Architecture

ServiceRadar uses a distributed architecture with three main components:

```mermaid
graph TD
    subgraph "Monitored Host"
        A[Agent] --> P1[Process Checker]
        A --> P2[Port Checker]
        A --> P3[Dusk Checker]
    end

    subgraph "Local Network"
        P[Poller] --> A
        P --> A2[Agent 2]
        P --> HTTP[HTTP Checks]
        
        subgraph "Agent 2 Host"
            A2 --> R[Redis Status]
            A2 --> M[MySQL Status]
        end
        
        subgraph "Direct Checks"
            HTTP --> WebApp[Web Application]
            HTTP --> API[API Endpoint]
        end
    end
    
    subgraph "Cloud/Internet"
        P --> CS[Cloud Service]
        CS --> WH[Webhook Alerts]
        WH --> Discord[Discord]
        WH --> Custom[Custom Webhooks]
    end

    style P fill:#f9f,stroke:#333
    style CS fill:#bbf,stroke:#333
    style WH fill:#fbf,stroke:#333
```

### Components

1. **Agent** (runs on monitored hosts)
  - Provides service status through gRPC
  - Supports multiple checker types:
    - Process checker (systemd services)
    - Port checker (TCP ports)
    - Custom checkers (e.g., Dusk node)
  - Must run on each host you want to monitor

2. **Poller** (runs anywhere in your network)
  - Coordinates monitoring activities
  - Can run on the same host as an agent or separately
  - Polls agents at configurable intervals
  - Reports status to cloud service
  - Multiple pollers can report to the same cloud service

3. **Cloud Service** (runs on a reliable host)
  - Receives reports from pollers
  - Provides web dashboard
  - Sends alerts via webhooks (Discord, etc.)
  - Should run on a reliable host outside your network

## Installation

ServiceRadar components are distributed as Debian packages. Each component has its own package:

### Building Packages

1. Clone the repository:
```bash
git clone https://github.com/mfreeman451/serviceradar.git
cd serviceradar
```

2. Build the agent package:
```bash
./setup-deb-agent.sh
```

3. Build the poller package:
```bash
./setup-deb-poller.sh
```

4. Build the cloud package:
```bash
./setup-deb-cloud.sh
```

5. Build the dusk provisioner node package (optional):
```bash
./setup-deb-dusk-checker.sh
```

### Installation Order and Location

1. **Agent Installation** (on monitored hosts):
```bash
sudo dpkg -i serviceradar-dusk-checker_1.0.8.deb  # For Dusk nodes
# or
sudo dpkg -i serviceradar-agent_1.0.8.deb  # For other hosts
```

2. **Poller Installation** (on any host in your network):
```bash
sudo dpkg -i serviceradar-poller_1.0.8.deb
```

3. **Cloud Installation** (on a reliable host):
```bash
sudo dpkg -i serviceradar-cloud_1.0.8.deb
```

## Configuration

### Agent Configuration

Default location: ***/etc/serviceradar/***

**/etc/serviceradar/agent.json**

```json
{
    "checkers_dir": "/etc/serviceradar/checkers",
    "listen_addr": ":50051",
    "service_type": "grpc",
    "service_name": "AgentService"
}
```

For Dusk nodes:

**/etc/serviceradar/checkers/dusk.json**

```json
{
    "name": "dusk",
    "type": "grpc",
    "node_address": "localhost:8080",
    "address": "localhost:50052",
    "listen_addr": ":50052",
    "timeout": "5m"
}
```
**/etc/serviceradar/checkers/external.json**

```json
{
    "name": "dusk",
    "address": "localhost:50052"
}
```

For Network Sweep:

**/etc/serviceradar/checkers/sweep.json**

```json
{
    "networks": ["192.168.2.0/24"],
    "ports": [22, 80, 443, 3306, 5432, 6379, 8080, 8443],
    "sweep_modes": ["icmp", "tcp"],
    "interval": "5m",
    "concurrency": 100,
    "timeout": "10s"
}
```

### Poller Configuration

Default location: `/etc/serviceradar/poller.json`

```json
{
  "agents": {
    "local-agent": {
      "address": "127.0.0.1:50051",
      "checks": [
        {
          "service_type": "process",
          "service_name": "rusk",
          "details": "rusk"
        },
        {
          "service_type": "port",
          "service_name": "SSH",
          "details": "127.0.0.1:22"
        },
        {
          "service_type": "grpc",
          "service_name": "dusk",
          "details": "127.0.0.1:50052"
        },
        {
          "service_type": "icmp",
          "service_name": "ping",
          "details": "8.8.8.8"
        },
        {
          "service_type": "sweep",
          "service_name": "network_sweep",
          "details": ""
        }
      ]
    }
  },
  "cloud_address": "changeme:50052",
  "listen_addr": ":50053",
  "poll_interval": "30s",
  "poller_id": "dusk",
  "service_name": "PollerService",
  "service_type": "grpc"
}
```

### Cloud Configuration

Default location: `/etc/serviceradar/cloud.json`

```json
{
  "listen_addr": ":8090",
  "grpc_addr": ":50052",
  "alert_threshold": "5m",
  "known_pollers": ["home-poller-1"],
  "metrics": {
    "enabled": true,
    "retention": 100,
    "max_nodes": 10000
  },
  "webhooks": [
    {
      "enabled": false,
      "url": "https://your-webhook-url",
      "cooldown": "15m",
      "headers": [
        {
          "key": "Authorization",
          "value": "Bearer your-token"
        }
      ]
    },
    {
      "enabled": true,
      "url": "https://discord.com/api/webhooks/changeme",
      "cooldown": "15m",
      "template": "{\"embeds\":[{\"title\":\"{{.alert.Title}}\",\"description\":\"{{.alert.Message}}\",\"color\":{{if eq .alert.Level \"error\"}}15158332{{else if eq .alert.Level \"warning\"}}16776960{{else}}3447003{{end}},\"timestamp\":\"{{.alert.Timestamp}}\",\"fields\":[{\"name\":\"Node ID\",\"value\":\"{{.alert.NodeID}}\",\"inline\":true}{{range $key, $value := .alert.Details}},{\"name\":\"{{$key}}\",\"value\":\"{{$value}}\",\"inline\":true}{{end}}]}]}"
    }
  ]
}
```

## Deployment Recommendations

1. **Agent Deployment**:
  - Must run on each host you want to monitor
  - For Dusk nodes, use the serviceradar-dusk package
  - For other hosts, use the serviceradar-agent package
  - Requires port 50051 to be accessible to the poller

2. **Poller Deployment**:
  - Can run on the same host as an agent or separately
  - Must be able to reach all agents
  - Must be able to reach the cloud service
  - Multiple pollers can report to the same cloud service
  - Each poller needs a unique poller_id

3. **Cloud Service Deployment**:
  - Should run on a reliable host outside your network
  - Needs to be accessible by all pollers
  - Provides web interface on port 8090
  - Should have reliable internet for webhook alerts

### Firewall Configuration

If you're using UFW (Ubuntu's Uncomplicated Firewall), here are the required rules:

```bash
# On agent hosts
sudo ufw allow 50051/tcp  # For agent gRPC server
sudo ufw allow 50052/tcp  # For Dusk checker (if applicable)

# On cloud host
sudo ufw allow 50052/tcp  # For poller connections
sudo ufw allow 8090/tcp   # For web interface
```

## Web Interface

The web interface is available at `http://cloud-host:8090` and provides:
- Overall system status
- Individual node status
- Service status for each node
- Historical availability data
- Dusk node specific information

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the Apache 2.0 License - see the LICENSE file for details.
