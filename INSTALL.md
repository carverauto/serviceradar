# ServiceRadar Installation

ServiceRadar is typically deployed as a platform stack (Docker Compose or Kubernetes/Helm) plus edge agents installed at monitored sites.

## Platform Deployment

### Docker Compose

```bash
git clone https://github.com/carverauto/serviceradar.git
cd serviceradar
cp .env-sample .env
docker compose up -d

# Get your admin password
docker compose logs config-updater | grep \"Password:\"
```

### Kubernetes (Helm)

```bash
helm upgrade --install serviceradar oci://registry.carverauto.dev/serviceradar/charts/serviceradar \
  --version <chart-version> -n serviceradar --create-namespace -f my-values.yaml
```

`<chart-version>` is the release version without the leading `v` (release `vX.Y.Z` is chart `X.Y.Z`). `my-values.yaml` holds only the keys you override and can start empty (`touch my-values.yaml`). The chart and its images pull anonymously, so no repository checkout or registry login is needed.

### Verify Harbor Images

ServiceRadar signs published Harbor images with Cosign. The public key is available in [docs/cosign.pub](docs/cosign.pub).

Verification commands, including the keyless path, are in
[Verifying published images](docs/sigstore/README.md#verifying-published-images).

## Edge Agent Deployment

Edge agents are installed using the edge onboarding flow from the web UI (generating an agent package/config for a specific gateway and security mode).

See `docs/docs/edge-agent-onboarding.md` for the current workflow.

## Architecture Overview

- `serviceradar-agent` (edge): collectors + embedded engines + sandboxed Wasm plugins
- `agent-gateway`: mTLS gRPC ingress for agents (streaming + command bus)
- `core-elx`, `web-ng`: control plane services (ERTS cluster)
- `NATS JetStream`: bulk ingestion streams
- `CNPG`: system of record (Postgres + Timescale + AGE)
