---
sidebar_position: 2
title: Installation Guide
---

# Installation Guide

ServiceRadar platform services are deployed with Kubernetes or Docker Compose. Standalone installs are supported for edge agents and checkers only.

## Platform Deployment

### Docker Compose

```bash
git clone https://github.com/carverauto/serviceradar.git
cd serviceradar
cp .env.example .env

docker compose up -d

# Get your admin password
docker compose logs config-updater | grep "Password:"
```

Access ServiceRadar at http://localhost (Caddy). The API is available at http://localhost/api or http://localhost:8090.

### Kubernetes / Helm

```bash
helm upgrade --install serviceradar oci://ghcr.io/carverauto/charts/serviceradar \
  --version 1.0.75 \
  -n serviceradar --create-namespace \
  --set global.imageTag="v1.0.75"
```

## Edge Deployment

Use the install script or packages to deploy agents and optional checkers on monitored hosts.

```bash
curl -sSL https://github.com/carverauto/serviceradar/releases/download/1.0.52/install-serviceradar.sh | bash -s -- --agent --non-interactive
```

## Next Steps

- [Architecture](./architecture.md)
- [TLS Security](./tls-security.md)
- [Edge Agents](./edge-agents.md)
