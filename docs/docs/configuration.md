---
sidebar_position: 3
title: Configuration Basics
---

# Configuration Basics

ServiceRadar components are configured via JSON files in `/etc/serviceradar/`. This guide covers the essential configurations needed to get your monitoring system up and running.

## Agent Configuration

The agent runs on each monitored host and collects status information from services.

Edit `/etc/serviceradar/agent.json`:

```json
{
  "checkers_dir": "/etc/serviceradar/checkers",
  "listen_addr": ":50051",
  "service_type": "grpc",
  "service_name": "AgentService",
  "security": {
    "mode": "none",
    "cert_dir": "/etc/serviceradar/certs",
    "server_name": "changeme",
    "role": "agent"
  }
}
```

### Configuration Options:

- `checkers_dir`: Directory containing checker configurations
- `listen_addr`: Address and port the agent listens on
- `service_type`: Type of service (should be "grpc")
- `security`: Security settings
  - `mode`: Security mode ("none" or "mtls")
  - `cert_dir`: Directory for TLS certificates
  - `server_name`: Hostname/IP of the poller (important for TLS)
  - `role`: Role of this component ("agent")

## Poller Configuration

The poller contacts agents to collect monitoring data and reports to the core service.

Edit `/etc/serviceradar/poller.json`:

```json
{
  "agents": {
    "local-agent": {
      "address": "localhost:50051",
      "security": { 
        "server_name": "changeme", 
        "mode": "none" 
      },
      "checks": [
        { "service_type": "process", "service_name": "nginx", "details": "nginx" },
        { "service_type": "port", "service_name": "SSH", "details": "127.0.0.1:22" },
        { "service_type": "icmp", "service_name": "ping", "details": "8.8.8.8" }
      ]
    }
  },
  "core_address": "changeme:50052",
  "listen_addr": ":50053",
  "poll_interval": "30s",
  "poller_id": "my-poller",
  "service_name": "PollerService",
  "service_type": "grpc",
  "security": {
    "mode": "none",
    "cert_dir": "/etc/serviceradar/certs",
    "server_name": "changeme",
    "role": "poller"
  }
}
```

### Configuration Options:

- `agents`: Map of agents to monitor
  - Each agent has an `address`, `security` settings, and `checks` to perform
- `core_address`: Address of the core service
- `listen_addr`: Address and port the poller listens on
- `poll_interval`: How often to poll agents
- `poller_id`: Unique identifier for this poller
- `security`: Security settings (similar to agent)

### Check Types:

- `process`: Check if a process is running
- `port`: Check if a TCP port is responding
- `icmp`: Ping a host
- `grpc`: Check a gRPC service
- `snmp`: Check via SNMP (requires snmp checker)
- `sweep`: Network sweep check

## Core Configuration

The core service receives reports from pollers and provides the API backend.

Edit `/etc/serviceradar/core.json`:

```json
{
  "listen_addr": ":8090",
  "grpc_addr": ":50052",
  "alert_threshold": "5m",
  "known_pollers": ["my-poller"],
  "metrics": {
    "enabled": true,
    "retention": 100,
    "max_nodes": 10000
  },
  "security": {
    "mode": "none",
    "cert_dir": "/etc/serviceradar/certs",
    "role": "core"
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

### API Key

During installation, the core service automatically generates an API key, stored in:

```
/etc/serviceradar/api.env
```

This API key is used for secure communication between the web UI and the core API. The key is automatically injected into API requests by the web UI's middleware, ensuring secure communication without exposing the key to clients.
```

### Configuration Options:

- `listen_addr`: Address and port for web dashboard
- `grpc_addr`: Address and port for gRPC service
- `alert_threshold`: How long a service must be down before alerting
- `known_pollers`: List of poller IDs that can connect
- `metrics`: Metrics collection settings
- `security`: Security settings (similar to agent)
- `webhooks`: List of webhook configurations for alerts

## Optional Checker Configurations

### SNMP Checker

For monitoring network devices via SNMP, edit `/etc/serviceradar/checkers/snmp.json`:

```json
{
  "node_address": "localhost:50051",
  "listen_addr": ":50054",
  "security": {
    "server_name": "changeme",
    "mode": "none",
    "role": "checker",
    "cert_dir": "/etc/serviceradar/certs"
  },
  "timeout": "30s",
  "targets": [
    {
      "name": "router",
      "host": "192.168.1.1",
      "port": 161,
      "community": "public",
      "version": "v2c",
      "interval": "30s",
      "retries": 2,
      "oids": [
        {
          "oid": ".1.3.6.1.2.1.2.2.1.10.4",
          "name": "ifInOctets_4",
          "type": "counter",
          "scale": 1.0
        }
      ]
    }
  ]
}
```

### Dusk Node Checker

For monitoring Dusk nodes, edit `/etc/serviceradar/checkers/dusk.json`:

```json
{
  "name": "dusk",
  "type": "grpc",
  "node_address": "localhost:8080",
  "address": "localhost:50052",
  "listen_addr": ":50052",
  "timeout": "5m",
  "security": {
    "mode": "none",
    "cert_dir": "/etc/serviceradar/certs",
    "role": "checker"
  }
}
```

### Network Sweep

For network scanning, edit `/etc/serviceradar/checkers/sweep/sweep.json`:

```json
{
  "networks": ["192.168.2.0/24", "192.168.3.1/32"],
  "ports": [22, 80, 443, 3306, 5432, 6379, 8080, 8443],
  "sweep_modes": ["icmp", "tcp"],
  "interval": "5m",
  "concurrency": 100,
  "timeout": "10s"
}
```

## Next Steps

After configuring your components:

1. Restart services to apply changes:

```bash
sudo systemctl restart serviceradar-agent
sudo systemctl restart serviceradar-poller
sudo systemctl restart serviceradar-core
```

2. Visit the web dashboard at `http://core-host:8090`

3. Review [TLS Security](./tls-security.md) to secure your components