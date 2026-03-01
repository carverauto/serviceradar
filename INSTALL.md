# ServiceRadar Installation

ServiceRadar is typically deployed as a platform stack (Docker Compose or Kubernetes/Helm) plus edge agents installed at monitored sites.

## Platform Deployment

### Docker Compose

```bash
git clone https://github.com/carverauto/serviceradar.git
cd serviceradar
cp .env.example .env
docker compose up -d

# Get your admin password
docker compose logs config-updater | grep \"Password:\"
```

### Kubernetes (Helm)

```bash
helm upgrade --install serviceradar oci://ghcr.io/carverauto/charts/serviceradar \
  -n serviceradar --create-namespace
```

## Edge Agent Deployment

Edge agents are installed using the edge onboarding flow from the web UI (generating an agent package/config for a specific gateway and security mode).

See `docs/docs/edge-agent-onboarding.md` for the current workflow.

## Architecture Overview

- `serviceradar-agent` (edge): collectors + embedded engines + sandboxed Wasm plugins
- `agent-gateway`: mTLS gRPC ingress for agents (streaming + command bus)
- `core-elx`, `web-ng`: control plane services (ERTS cluster)
- `NATS JetStream`: bulk ingestion streams
- `CNPG`: system of record (Postgres + Timescale + AGE)
