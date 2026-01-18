# ServiceRadar Installation Guide

## Overview

ServiceRadar platform services (core-elx, agent-gateway, web-ng, datasvc, nats, cnpg) are deployed with Kubernetes or Docker Compose. Standalone installs are supported for edge agents and checkers only.

## Platform Deployment (Recommended)

### Docker Compose

```bash
git clone https://github.com/carverauto/serviceradar.git
cd serviceradar
cp .env.example .env
docker compose up -d

# Get your admin password
docker compose logs config-updater | grep "Password:"
```

### Kubernetes / Helm

```bash
helm upgrade --install serviceradar oci://ghcr.io/carverauto/charts/serviceradar \
  --version 1.0.75 \
  -n serviceradar --create-namespace \
  --set global.imageTag="v1.0.75"
```

## Edge Deployment (Standalone)

Use the installation script or packages to install agents and checkers on monitored hosts.

### Install Script (Agent + Optional Checkers)

```bash
curl -sSL https://github.com/carverauto/serviceradar/releases/download/1.0.52/install-serviceradar.sh | bash -s -- --agent --non-interactive

# With optional checkers
curl -sSL https://github.com/carverauto/serviceradar/releases/download/1.0.52/install-serviceradar.sh | bash -s -- --agent --non-interactive --checkers=rperf,snmp
```

### Manual Package Install (Agent + Checkers)

```bash
# Agent
curl -LO https://github.com/carverauto/serviceradar/releases/download/1.0.52/serviceradar-agent_1.0.52.deb
sudo dpkg -i serviceradar-agent_1.0.52.deb

# Optional checkers
```

## Architecture Overview

ServiceRadar uses a distributed architecture with four main components:

1. **Agent** - Runs on monitored hosts, collects data, and pushes results to agent-gateway over gRPC
2. **Agent-Gateway** - Receives agent streams and forwards them to core-elx
3. **Core Service (core-elx)** - Control plane for DIRE, ingestion, APIs, and alerts
4. **Web UI (web-ng)** - Phoenix LiveView dashboard served through the edge proxy

## Configuration

After installation, configuration files are located in `/etc/serviceradar/`. See our documentation for configuration and operational guidance.

## Further Documentation

**https://docs.serviceradar.cloud**
