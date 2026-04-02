# ServiceRadar Installation

ServiceRadar is typically deployed as a platform stack (Docker Compose or Kubernetes/Helm) plus edge agents installed at monitored sites.

## Platform Deployment

### Docker Compose

```bash
git clone https://code.carverauto.dev/carverauto/serviceradar.git
cd serviceradar
cp .env-sample .env
docker compose up -d

# Get your admin password
docker compose logs config-updater | grep \"Password:\"
```

### Kubernetes (Helm)

```bash
helm upgrade --install serviceradar oci://registry.carverauto.dev/serviceradar/charts/serviceradar \
  -n serviceradar --create-namespace
```

### Verify Harbor Images

ServiceRadar signs published Harbor images with Cosign. The public key is available in [docs/cosign.pub](/Users/mfreeman/src/serviceradar/docs/cosign.pub).

```bash
cosign verify \
  --experimental-oci11 \
  --key docs/cosign.pub \
  registry.carverauto.dev/serviceradar/serviceradar-core-elx:v1.2.10
```

Use immutable `sha-<commit>` tags when you want to verify an exact build:

```bash
cosign verify \
  --experimental-oci11 \
  --key docs/cosign.pub \
  registry.carverauto.dev/serviceradar/serviceradar-core-elx:sha-ac23dc0ebcbee0d6a964dc8307826bf2a063536c
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
