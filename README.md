<div align=center>
  
[![Website](https://img.shields.io/website?up_message=SERVICERADAR&down_message=DOWN&url=https%3A%2F%2Fserviceradar.cloud&style=for-the-badge)](https://serviceradar.cloud)
[![Demo](https://img.shields.io/website?label=Demo&up_color=blue&up_message=DEMO&down_message=DOWN&url=https%3A%2F%2Fdemo.serviceradar.cloud&style=for-the-badge)](https://demo.serviceradar.cloud)
[![Apache 2.0 License](https://img.shields.io/badge/license-Apache%202.0-blueviolet?style=for-the-badge)](https://www.apache.org/licenses/LICENSE-2.0)

</div>

# ServiceRadar

<img width="1470" height="836" alt="Screenshot 2025-12-16 at 10 09 19 PM" src="https://github.com/user-attachments/assets/e64ca26b-f4d8-42df-ab81-2de1d7941f92" />

[![CI](https://github.com/carverauto/serviceradar/actions/workflows/main.yml/badge.svg)](https://github.com/carverauto/serviceradar/actions/workflows/main.yml)
[![Go Linter](https://github.com/carverauto/serviceradar/actions/workflows/golangci-lint.yml/badge.svg)](https://github.com/carverauto/serviceradar/actions/workflows/golangci-lint.yml)
[![Go Tests](https://github.com/carverauto/serviceradar/actions/workflows/tests-golang.yml/badge.svg)](https://github.com/carverauto/serviceradar/actions/workflows/tests-golang.yml)
[![Rust Tests](https://github.com/carverauto/serviceradar/actions/workflows/tests-rust.yml/badge.svg)](https://github.com/carverauto/serviceradar/actions/workflows/tests-rust.yml)

[![CNCF Landscape](https://img.shields.io/badge/CNCF%20Landscape-5699C6)](https://landscape.cncf.io/?item=observability-and-analysis--observability--serviceradar)
[![FOSSA Status](https://app.fossa.com/api/projects/custom%2B57999%2Fgit%40github.com%3Acarverauto%2Fserviceradar.git.svg?type=shield&issueType=security)](https://app.fossa.com/projects/custom%2B57999%2Fgit%40github.com%3Acarverauto%2Fserviceradar.git?ref=badge_shield&issueType=security)
[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/11310/badge)](https://www.bestpractices.dev/projects/11310)
<a href="https://cla-assistant.io/carverauto/serviceradar"><img src="https://cla-assistant.io/readme/badge/carverauto/serviceradar" alt="CLA assistant" /></a>
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/carverauto/serviceradar)

ServiceRadar is a distributed network monitoring system designed for infrastructure and services in hard-to-reach places or constrained environments. It provides real-time monitoring of internal services with cloud-based alerting to ensure you stay informed even during network or power outages.

## Features

- **Distributed Architecture**: Multi-component design (Agent, Gateway, Core) for flexible edge deployments.
- **WASM Plugin System**: Securely extend monitoring with custom checks in Go or Rust. Runs in a hardware-level sandbox with zero local dependencies and proxied networking.
- **SRQL**: intuitive key:value syntax for querying time-series and relational data.
- **Unified Data Layer**: Powered by CloudNativePG, TimescaleDB, and Apache AGE for relational, time-series, and graph topology data.
- **Observability**: Native support for OTEL, GELF, Syslog, SNMP (polling/traps), and NetFlow (planned).
- **Graph Network Mapper**: Discovery engine that maps interfaces and topology relationships via SNMP/LLDP/CDP.
- **Security**: Hardened with mTLS ([SPIFFE/spire](http://spiffe.io/)), RBAC, and SSO integration.

## WASM-Based Extensibility

ServiceRadar replaces traditional "script-and-shell" plugins with a [modern WebAssembly runtime](https://github.com/wazero/wazero). This provides a generation leap in security and portability:

| Feature | ServiceRadar (WASM) | Traditional NMS (Nagios/Zabbix) | Enterprise (SolarWinds) |
| :--- | :--- | :--- | :--- |
| **Isolation** | **Hardware Sandbox** | None (OS Process) | None (User Session) |
| **Dependencies** | **Zero** (Static Binaries) | High (Local Libs/Python) | High (.NET/Runtimes) |
| **Security** | Capability-based (Proxy) | Sudo/Root access | Local Admin / WMI |
| **Portability** | Cross-platform WASM | Script-specific | Windows-centric |
| **Auditability** | Every network call logged | Invisible to Agent | Opaque |

**Why WASM?** Plugins are "FS-less" by default. They cannot access the host filesystem or raw sockets. Instead, they use a **Network Bridge** where the Agent proxies specific HTTP/TCP calls based on admin-approved allowlists.

## Quick Installation (Docker Compose)

Get ServiceRadar running in under 5 minutes:

```bash
git clone https://github.com/carverauto/serviceradar.git
cd serviceradar
docker compose up -d

# Get your admin password
docker compose logs config-updater
```

**Access:** http://localhost (login: `root@localhost`)

## Kubernetes / Helm Deployment

ServiceRadar provides an official Helm chart for Kubernetes deployments, published to GHCR as an OCI artifact.

```bash
# Inspect chart metadata and default values
helm show chart oci://ghcr.io/carverauto/charts/serviceradar --version 1.0.84
helm show values oci://ghcr.io/carverauto/charts/serviceradar --version 1.0.84 > values.yaml

# Install a pinned release (recommended)
helm upgrade --install serviceradar oci://ghcr.io/carverauto/charts/serviceradar \
  --version 1.0.84 \
  -n serviceradar --create-namespace \
  --set global.imageTag="v1.0.84"

# Track mutable images (staging/dev): pulls :latest and forces re-pull
helm upgrade --install serviceradar oci://ghcr.io/carverauto/charts/serviceradar \
  --version 1.0.84 \
  -n serviceradar --create-namespace \
  --set global.imageTag="latest" \
  --set global.imagePullPolicy="Always"

# Get password for 'root@localhost' user created by helm install
 kubectl get secret serviceradar-secrets -n demo \
    -o jsonpath='{.data.admin-password}' | base64 -d
```

Note: if you omit `global.imageTag`, the chart defaults to `latest`. Set `global.imagePullPolicy=Always` when you want to pick up new pushes on restart.

Docker Compose notes:
- Set `APP_TAG` in `.env` to pin release images (example: `APP_TAG=v1.0.84`).
- Set `COMPOSE_FILE=docker-compose.yml:docker-compose.dev.yml` in `.env` to default to the dev overlay without `-f`.

**Chart URL:** `oci://ghcr.io/carverauto/charts/serviceradar`

Notes:
- [Chart](https://github.com/carverauto/serviceradar/blob/staging/helm/serviceradar/Chart.yaml) versions are like `1.0.84`; ServiceRadar image tags are like `v1.0.84`.
- If your cluster requires registry credentials, set `image.registryPullSecret` (default `ghcr-io-cred`).

For ArgoCD deployments, use `ghcr.io/carverauto/charts` as the repository URL (without the `oci://` prefix):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: serviceradar
  namespace: argocd
spec:
  destination:
    server: https://kubernetes.default.svc
    namespace: serviceradar
  source:
    repoURL: ghcr.io/carverauto/charts
    chart: serviceradar
    targetRevision: "1.0.84"
    helm:
      values: |
        global:
          imageTag: "v1.0.84"
```

## Architecture

1. **Agent**: Lightweight Go service on monitored hosts; manages WASM execution and local collection.
2. **Agent-Gateway**: Ingestion point that receives gRPC streams from edge agents.
3. **Core (core-elx)**: Control plane (Elixir/Phoenix) for orchestration, APIs, and alerts.
4. **Web UI (web-ng)**: Real-time LiveView dashboard for configuration and visualization.

## Documentation

For detailed guides on setup, security, and WASM SDK usage, visit:
**[https://docs.serviceradar.cloud](https://docs.serviceradar.cloud)**

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request. Join our [Discord](https://discord.gg/dhaNgF9d3g)! 

## License

Apache 2.0 License - see the [LICENSE](LICENSE) file for details.
