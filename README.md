# ServiceRadar

```
.-----.-----.----.--.--.|__|.----.-----.----.---.-.--|  |.---.-.----.
|__ --|  -__|   _|  |  ||  ||  __|  -__|   _|  _  |  _  ||  _  |   _|
|_____|_____|__|  \___/ |__||____|_____|__| |___._|_____||___._|__|  
```
[![Release ServiceRadar Packages](https://github.com/mfreeman451/serviceradar/actions/workflows/release.yml/badge.svg)](https://github.com/mfreeman451/serviceradar/actions/workflows/release.yml)
[![lint](https://github.com/mfreeman451/serviceradar/actions/workflows/golangci-lint.yml/badge.svg)](https://github.com/mfreeman451/serviceradar/actions/workflows/golangci-lint.yml)
[![test](https://github.com/mfreeman451/serviceradar/actions/workflows/go-coverage.yml/badge.svg)](https://github.com/mfreeman451/serviceradar/actions/workflows/go-coverage.yml)

ServiceRadar is a distributed network monitoring system designed for monitoring infrastructure and services in hard to reach places or constrained environments. 
It provides real-time monitoring of internal services, with cloud-based alerting capabilities to ensure you stay informed even during network or power outages.

<img width="1391" alt="Screenshot 2025-01-18 at 11 53 12 AM" src="https://github.com/user-attachments/assets/fa37618f-a089-4863-a5e0-8c05205774fd" />
<img width="1389" alt="Screenshot 2025-01-18 at 11 53 41 AM" src="https://github.com/user-attachments/assets/da942f14-30e4-4d69-8971-a33949bdfbd1" />
<img width="1389" alt="Screenshot 2025-01-18 at 11 54 04 AM" src="https://github.com/user-attachments/assets/45099e35-8c38-49b4-898a-537569f6f0a8" />
<img width="1389" alt="Screenshot 2025-01-18 at 11 54 22 AM" src="https://github.com/user-attachments/assets/f6a0b3e1-da93-48f6-9288-887f13d953b0" />
<img width="1389" alt="Screenshot 2025-01-18 at 11 54 49 AM" src="https://github.com/user-attachments/assets/24a1be84-9af3-4c92-84c1-5cda64af6c01" />

**Monitoring a Dusk Node**
<img width="1389" alt="Screenshot 2025-01-18 at 11 55 09 AM" src="https://github.com/user-attachments/assets/f1383d3b-971b-4a76-aa25-af435adfb1e6" />

https://docs.dusk.network/operator/overview/

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

### Installation Order and Location

1. **Agent Installation** (on monitored hosts):
```bash
sudo dpkg -i serviceradar-dusk_1.0.0.deb  # For Dusk nodes
# or
sudo dpkg -i serviceradar-agent_1.0.0.deb  # For other hosts
```

2. **Poller Installation** (on any host in your network):
```bash
sudo dpkg -i serviceradar-poller_1.0.0.deb
```

3. **Cloud Installation** (on a reliable host):
```bash
sudo dpkg -i serviceradar-cloud_1.0.0.deb
```

## Configuration

### Agent Configuration

Default location: `/etc/serviceradar/checkers/`

For Dusk nodes:
```json
# /etc/serviceradar/checkers/dusk.json
{
    "name": "dusk",
    "node_address": "localhost:8080",
    "timeout": "5m",
    "listen_addr": ":50052"
}

# /etc/serviceradar/checkers/external.json
{
    "name": "dusk",
    "address": "localhost:50052"
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
                    "type": "dusk"
                }
            ]
        }
    },
    "cloud_address": "cloud-host:50052",
    "poll_interval": "30s",
    "poller_id": "home-poller-1"
}
```

### Cloud Configuration

Default location: `/etc/serviceradar/cloud.json`

```json
{
    "listen_addr": ":8090",
    "alert_threshold": "5m",
    "known_pollers": ["home-poller-1"],
    "webhooks": [
        {
            "enabled": true,
            "url": "https://discord.com/api/webhooks/your-webhook-url",
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
