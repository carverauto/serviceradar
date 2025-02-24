---
sidebar_position: 3
title: Configuration Basics
---

# Configuration Basics

ServiceRadar components are configured via JSON files in `/etc/serviceradar/`. Below are the essentials to get started.

## Agent Configuration
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

* Update server_name to your poller’s hostname/IP if using mTLS (set mode to mtls).

## Poller Configuration

Edit `/etc/serviceradar/poller.json`:

```json
{
  "agents": {
    "local-agent": {
      "address": "localhost:50051",
      "security": { "mode": "none" },
      "checks": [
        { "service_type": "port", "service_name": "SSH", "details": "127.0.0.1:22" }
      ]
    }
  },
  "cloud_address": "changeme:50052",
  "listen_addr": ":50053",
  "poll_interval": "30s",
  "poller_id": "my-poller",
  "security": { "mode": "none" }
}
```

* Set `cloud_address` to your cloud service’s hostname/IP.
* Adjust `agents` to list your monitored hosts.

## Cloud Configuration

Edit `/etc/serviceradar/cloud.json`:

```json
{
  "listen_addr": ":8090",
  "grpc_addr": ":50052",
  "alert_threshold": "5m",
  "known_pollers": ["my-poller"],
  "security": { "mode": "none" }
}
```

* Update `known_pollers` with your poller IDs.

For mTLS setup and advanced options, see the full README on GitHub.

