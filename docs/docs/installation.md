---
sidebar_position: 2
title: Installation Guide
---

# Installation Guide

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

Access ServiceRadar at http://localhost (Caddy). The API is available at http://localhost/api (via proxy) or http://localhost:8090.

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
curl -LO https://github.com/carverauto/serviceradar/releases/download/1.0.52/serviceradar-snmp-checker_1.0.52.deb
sudo dpkg -i serviceradar-snmp-checker_1.0.52.deb
```

## Optional Checkers

### SNMP Monitoring

```bash
curl -LO https://github.com/carverauto/serviceradar/releases/download/1.0.52/serviceradar-snmp-checker_1.0.52.deb
sudo dpkg -i serviceradar-snmp-checker_1.0.52.deb
```

### rperf Network Performance Monitoring

```bash
# Debian/Ubuntu
curl -LO https://github.com/mfreeman451/rperf/releases/download/v1.0.52/serviceradar-rperf_1.0.52.deb
curl -LO https://github.com/mfreeman451/rperf/releases/download/v1.0.52/serviceradar-rperf-checker_1.0.52.deb
sudo dpkg -i serviceradar-rperf_1.0.52.deb serviceradar-rperf-checker_1.0.52.deb
```

### Dusk Node Monitoring

```bash
curl -LO https://github.com/carverauto/serviceradar/releases/download/1.0.52/serviceradar-dusk-checker_1.0.52.deb
sudo dpkg -i serviceradar-dusk-checker_1.0.52.deb
```

## Firewall Notes

- Edge agents require outbound access to the Agent-Gateway gRPC port (default 50052).
- Optional checkers may require additional ports depending on their protocol.

## Next Steps

- [Architecture](./architecture.md)
- [TLS Security](./tls-security.md)
- [Edge Agents](./edge-agents.md)
