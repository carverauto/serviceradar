---
sidebar_position: 2
title: Installation Guide
---

# Installation Guide

ServiceRadar platform services are deployed with Kubernetes or Docker Compose. Edge agents are deployed using the onboarding flow from the web UI (generating an agent package/config scoped to a gateway and security mode).

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

Access ServiceRadar at http://localhost (Caddy). Log in with `root@localhost` and the password from the logs. The API is available at http://localhost/api or http://localhost:8090.

### Kubernetes / Helm

```bash
helm upgrade --install serviceradar helm/serviceradar \
  -n serviceradar --create-namespace
```

Helm upgrades reuse existing CNPG secrets (`cnpg-superuser`, `serviceradar-db-credentials`,
`spire-db-credentials`) and will not rotate passwords automatically. To move off
legacy/static credentials, update or delete those secrets before running the
upgrade so Helm can generate new random values.

## Edge Deployment

Use the edge onboarding flow and install the generated agent package on the target host.

See:

- [Edge Agent Onboarding](./edge-agent-onboarding.md)

## Next Steps

- [Architecture](./architecture.md)
- [TLS Security](./tls-security.md)
- [Edge Model](./edge-model.md)
