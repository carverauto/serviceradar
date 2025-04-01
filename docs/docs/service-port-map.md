---
sidebar_position: 11
title: Service Port Map
---

# ServiceRadar Service Port Map

This page provides a comprehensive reference of all ServiceRadar components and their network ports. Use this information when configuring your deployment, setting up firewall rules, or troubleshooting connectivity issues.

## Core Components

The following table lists the primary ServiceRadar components and their default listening ports:

| Component | Default Port | Protocol | Purpose |
|-----------|--------------|----------|---------|
| Agent | 50051 | gRPC/TCP | Service status collection and reporting |
| Core Service API | 8090 | HTTP/TCP | API for Web UI and external integrations |
| Core Service gRPC | 50052 | gRPC/TCP | Communication with Pollers |
| Poller | 50053 | gRPC/TCP | Coordination of monitoring activities |
| Web UI (Next.js) | 3000 | HTTP/TCP | Web interface (accessed via Nginx) |
| Nginx | 80/443 | HTTP(S)/TCP | Web UI reverse proxy |

## Storage and Configuration

| Component | Default Port | Protocol | Purpose |
|-----------|--------------|----------|---------|
| KV Store | 50057 | gRPC/TCP | Key-value store for dynamic configuration |
| NATS JetStream | 4222 | TCP | Messaging and KV storage (localhost only) |
| Sync Service | 50058 | gRPC/TCP | Integration with external data sources |

## Checker Components

| Component | Default Port | Protocol | Purpose |
|-----------|--------------|----------|---------|
| SNMP Checker | 50080        | gRPC/TCP | SNMP monitoring |
| rperf Checker | 50081        | gRPC/TCP | Network performance monitoring client |
| Dusk Checker | 50082        | gRPC/TCP | Dusk network node monitoring |

## Network Performance Components

| Component | Port Range | Protocol | Purpose |
|-----------|------------|----------|---------|
| rperf Server | 5199 | TCP/UDP | Network performance server control port |
| rperf Data Ports | 5200-5210 | TCP/UDP | Network performance test traffic |

## Important Considerations

### Security Recommendations

- **NATS JetStream** (port 4222) is configured by default to listen only on localhost (`127.0.0.1`) for security reasons. Only expose this externally if absolutely necessary.
- **Next.js Web UI** (port 3000) should not be directly exposed to the internet. Use Nginx as a reverse proxy as configured by default.
- When using mTLS security, ensure certificates are correctly deployed to each component.

### Firewall Configuration

For a typical installation with components on different hosts, the following ports should be opened:

```bash
# On Agent hosts
sudo ufw allow 50051/tcp  # For agent gRPC server

# On Core host
sudo ufw allow 50052/tcp  # For poller connections
sudo ufw allow 8090/tcp   # For API (internal use)
sudo ufw allow 80/tcp     # For web interface (or 443 for HTTPS)

# On KV Store host
sudo ufw allow 50057/tcp  # For ServiceRadar KV service

# On hosts running rperf server
sudo ufw allow 5199/tcp   # rperf server control port
sudo ufw allow 5200:5210/tcp  # rperf data ports
```

For co-located deployments, many of these ports can remain restricted to localhost only.

### Configuration Files

Each component's port can be customized in its respective configuration file:

| Component | Configuration File |
|-----------|-------------------|
| Agent | `/etc/serviceradar/agent.json` |
| Core Service | `/etc/serviceradar/core.json` |
| Poller | `/etc/serviceradar/poller.json` |
| KV Store | `/etc/serviceradar/kv.json` |
| Sync Service | `/etc/serviceradar/sync.json` |
| Web UI | `/etc/serviceradar/web.json` |
| SNMP Checker | `/etc/serviceradar/checkers/snmp.json` |
| Dusk Checker | `/etc/serviceradar/checkers/dusk.json` |
| rperf Checker | `/etc/serviceradar/checkers/rperf.json` |
| NATS Server | `/etc/nats/nats-server.conf` |
| Nginx | `/etc/nginx/conf.d/serviceradar-web.conf` |

## Next Steps

- Review [TLS Security](./tls-security.md) to secure communication between components
- Set up [Firewall Configuration](./installation.md#firewall-configuration) based on your deployment model
- Check [Troubleshooting](./installation.md#troubleshooting) if you encounter connectivity issues