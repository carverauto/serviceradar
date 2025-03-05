---
sidebar_position: 2
title: Installation Guide
---

# Installation Guide

ServiceRadar components are distributed as Debian packages. Below are the recommended installation steps for different deployment scenarios.

## Standard Setup (Recommended)

Install these components on your monitored host:

```bash
# Download and install agent and poller components
curl -LO https://github.com/carverauto/serviceradar/releases/download/1.0.21/serviceradar-agent_1.0.21.deb \
     -O https://github.com/carverauto/serviceradar/releases/download/1.0.21/serviceradar-poller_1.0.21.deb

sudo dpkg -i serviceradar-agent_1.0.21.deb serviceradar-poller_1.0.21.deb
```

On a separate machine (recommended) or the same host for the core service:

```bash
# Download and install core service
curl -LO https://github.com/carverauto/serviceradar/releases/download/1.0.21/serviceradar-core_1.0.21.deb
sudo dpkg -i serviceradar-core_1.0.21.deb
```

To install the web UI (dashboard):

```bash
# Download and install web UI
curl -LO https://github.com/carverauto/serviceradar/releases/download/1.0.21/serviceradar-web_1.0.21.deb
sudo dpkg -i serviceradar-web_1.0.21.deb
```

## Optional Components

### SNMP Polling

For collecting and visualizing metrics from network devices:

```bash
curl -LO https://github.com/carverauto/serviceradar/releases/download/1.0.21/serviceradar-snmp-checker_1.0.21.deb
sudo dpkg -i serviceradar-snmp-checker_1.0.21.deb
```

### Dusk Node Monitoring

For specialized monitoring of [Dusk Network](https://dusk.network/) nodes:

```bash
curl -LO https://github.com/carverauto/serviceradar/releases/download/1.0.21/serviceradar-dusk-checker_1.0.21.deb
sudo dpkg -i serviceradar-dusk-checker_1.0.21.deb
```

## Distributed Setup

For larger deployments, install components on separate hosts:

1. **On monitored hosts** (install only the agent):

```bash
curl -LO https://github.com/carverauto/serviceradar/releases/download/1.0.21/serviceradar-agent_1.0.21.deb
sudo dpkg -i serviceradar-agent_1.0.21.deb
```

2. **On monitoring host** (install the poller):

```bash
curl -LO https://github.com/carverauto/serviceradar/releases/download/1.0.21/serviceradar-poller_1.0.21.deb
sudo dpkg -i serviceradar-poller_1.0.21.deb
```

3. **On core host** (install the core service):

```bash
curl -LO https://github.com/carverauto/serviceradar/releases/download/1.0.21/serviceradar-core_1.0.21.deb
sudo dpkg -i serviceradar-core_1.0.21.deb
```

## Verification

After installation, verify the services are running:

```bash
# Check agent status
systemctl status serviceradar-agent

# Check poller status
systemctl status serviceradar-poller

# Check core status
systemctl status serviceradar-core
```

## Firewall Configuration

If you're using UFW (Ubuntu's Uncomplicated Firewall), add these rules:

```bash
# On agent hosts
sudo ufw allow 50051/tcp  # For agent gRPC server
sudo ufw allow 50052/tcp  # For Dusk checker (if applicable)

# On core host
sudo ufw allow 50052/tcp  # For poller connections
sudo ufw allow 8090/tcp   # For API (internal use)

# If running web UI
sudo ufw allow 80/tcp     # For web interface
```

## Next Steps

After installation, proceed to:

1. [Configuration Basics](./configuration.md) to configure your components
2. [TLS Security](./tls-security.md) to secure communications between components