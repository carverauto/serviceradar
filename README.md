<div align=center>
  
[![Website](https://img.shields.io/website?up_message=SERVICERADAR&down_message=DOWN&url=https%3A%2F%2Fserviceradar.cloud&style=for-the-badge)](https://serviceradar.cloud)
[![Demo](https://img.shields.io/website?label=Demo&up_color=blue&up_message=DEMO&down_message=DOWN&url=https%3A%2F%2Fdemo.serviceradar.cloud&style=for-the-badge)](https://demo.serviceradar.cloud)
[![Apache 2.0 License](https://img.shields.io/badge/license-Apache%202.0-blueviolet?style=for-the-badge)](https://www.apache.org/licenses/LICENSE-2.0)

</div>

# ServiceRadar

<img width="1470" height="836" alt="Screenshot 2025-12-16 at 10 09 19 PM" src="https://github.com/user-attachments/assets/e64ca26b-f4d8-42df-ab81-2de1d7941f92" />
<img width="1470" height="836" alt="Screenshot 2025-12-16 at 10 11 40 PM" src="https://github.com/user-attachments/assets/5dff0ec7-2282-498d-8123-0850acac37e0" />

[![CI](https://github.com/carverauto/serviceradar/actions/workflows/main.yml/badge.svg)](https://github.com/carverauto/serviceradar/actions/workflows/main.yml)
[![Go Linter](https://github.com/carverauto/serviceradar/actions/workflows/golangci-lint.yml/badge.svg)](https://github.com/carverauto/serviceradar/actions/workflows/golangci-lint.yml)
[![Web Linter](https://github.com/carverauto/serviceradar/actions/workflows/web-lint.yml/badge.svg)](https://github.com/carverauto/serviceradar/actions/workflows/web-lint.yml)
[![Go Tests](https://github.com/carverauto/serviceradar/actions/workflows/tests-golang.yml/badge.svg)](https://github.com/carverauto/serviceradar/actions/workflows/tests-golang.yml)
[![Rust Tests](https://github.com/carverauto/serviceradar/actions/workflows/tests-rust.yml/badge.svg)](https://github.com/carverauto/serviceradar/actions/workflows/tests-rust.yml)

[![CNCF Landscape](https://img.shields.io/badge/CNCF%20Landscape-5699C6)](https://landscape.cncf.io/?item=observability-and-analysis--observability--serviceradar)
[![FOSSA Status](https://app.fossa.com/api/projects/custom%2B57999%2Fgit%40github.com%3Acarverauto%2Fserviceradar.git.svg?type=shield&issueType=security)](https://app.fossa.com/projects/custom%2B57999%2Fgit%40github.com%3Acarverauto%2Fserviceradar.git?ref=badge_shield&issueType=security)
[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/11310/badge)](https://www.bestpractices.dev/projects/11310)
<a href="https://cla-assistant.io/carverauto/serviceradar"><img src="https://cla-assistant.io/readme/badge/carverauto/serviceradar" alt="CLA assistant" /></a>
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/carverauto/serviceradar)

ServiceRadar is a distributed network monitoring system designed for infrastructure and services in hard to reach places or constrained environments.
It provides real-time monitoring of internal services, with cloud-based alerting capabilities to ensure you stay informed even during network or power outages.

## Features

- **Real-time Monitoring**: Monitor services and infrastructure in hard-to-reach places
- **Distributed Architecture**: Components can be installed across different hosts to suit your needs
- **SRQL**: ServiceRadar Query Language -- intuitive key:value syntax for querying data
- **Unified Data Layer**: Powered by CloudNativePG, TimescaleDB, and Apache AGE for relational, time-series, and graph data
- **Observability**: Collect metrics, logs and traces (OTEL, GELF, Syslog), SNMP (polling or traps), NetFlow (coming soon), RPerf (iperf3-clone), BGP (BMP collector planned), gNMI (planned)
- **Graph Network Mapper**: Advanced discovery engine using [Apache AGE](https://age.apache.org/) to map devices, interfaces, and topology relationships via SNMP/LLDP/CDP
- **Security**: Components secured with mTLS via [SPIFFE](http://spiffe.io/). RBAC for services (cert-based) and UI, and SSO integration
- **Rule Engine**: Blazing fast rust-based rule processing engine
- **Specialized Monitoring**: Support for specific node types like Dusk Network nodes

## Quick Installation

### Docker Compose (Recommended)

Get ServiceRadar running in under 5 minutes with Docker Compose:

```bash
# Clone and start
git clone https://github.com/carverauto/serviceradar.git
cd serviceradar
cp .env.example .env
docker compose up -d

# Get your admin password
docker compose logs config-updater | grep "Password:"
```

**Access ServiceRadar:** http://localhost (login: `admin` / password from above)

**Prerequisites:** Docker Engine 20.10+, Docker Compose 2.0+, 8GB+ RAM

For OS-specific setup instructions (AlmaLinux, Ubuntu, macOS), see [README-Docker.md](README-Docker.md).

For detailed installation options and component-specific deployments, see [INSTALL.md](INSTALL.md).

## Architecture Overview

ServiceRadar (SR) uses a distributed architecture with four main components:

1. **Agent** - Runs on monitored hosts, provides service status through gRPC
2. **Poller** - Coordinates monitoring activities, can run anywhere in your network
3. **Core Service** - Receives reports from pollers, provides API, and sends alerts
4. **Web UI** - Provides a modern dashboard interface with Nginx as a reverse proxy

## Kubernetes / Helm Deployment

ServiceRadar provides an official Helm chart for Kubernetes deployments, published to GHCR as an OCI artifact.

```bash
# Inspect chart metadata and default values
helm show chart oci://ghcr.io/carverauto/charts/serviceradar --version 1.0.75
helm show values oci://ghcr.io/carverauto/charts/serviceradar --version 1.0.75 > values.yaml

# Install a pinned release (recommended)
helm upgrade --install serviceradar oci://ghcr.io/carverauto/charts/serviceradar \
  --version 1.0.75 \
  -n serviceradar --create-namespace \
  --set global.imageTag="v1.0.75"

# Track mutable images (staging/dev): pulls :latest and forces re-pull
helm upgrade --install serviceradar oci://ghcr.io/carverauto/charts/serviceradar \
  --version 1.0.75 \
  -n serviceradar --create-namespace \
  --set global.imageTag="latest" \
  --set global.imagePullPolicy="Always"
```

**Chart URL:** `oci://ghcr.io/carverauto/charts/serviceradar`

Notes:
- Chart versions are like `1.0.75`; ServiceRadar image tags are like `v1.0.75`.
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
    targetRevision: "1.0.75"
    helm:
      values: |
        global:
          imageTag: "v1.0.75"
```

## Docker Deployment

ServiceRadar provides a complete Docker Compose stack with mTLS security, automatic certificate generation, and all components pre-configured.

### Services Included

- **Database** - PostgreSQL with TimescaleDB (metrics) and Apache AGE (graph topology)
- **Core API** - Main ServiceRadar API and business logic
- **Web UI** - Modern React-based dashboard with Nginx reverse proxy
- **Agent & Poller** - Distributed monitoring services
- **Observability** - OTEL collector, syslog (flowgger), SNMP traps
- **Network Discovery** - SNMP/LLDP network mapping
- **Kong Gateway** - API gateway with JWT authentication

### Common Commands

```bash
docker compose ps                    # View service status
docker compose logs -f core          # Follow logs for a service
docker compose restart core          # Restart a service
docker compose down                  # Stop all services
```

### Custom Configuration

```bash
# Create an override file for customizations
cp docker-compose.yml docker-compose.override.yml
vim docker-compose.override.yml
docker compose -f docker-compose.yml -f docker-compose.override.yml up -d
```

See [README-Docker.md](README-Docker.md) for detailed Docker setup and troubleshooting.

## Performance

[ServiceRadar](https://serviceradar.cloud/) utilizes a modern PostgreSQL ecosystem to deliver robust performance across different data types. By leveraging [TimescaleDB](https://github.com/timescale/timescaledb) for high-cardinality time-series ingestion and [Apache AGE](https://age.apache.org/) for complex graph traversals, ServiceRadar efficiently correlates network topology with performance metrics in real-time. This architecture ensures scalable storage and fast query execution for both historical analysis and live network mapping.


## Documentation

For detailed information on installation, configuration, and usage, please visit our documentation site:

**[https://docs.serviceradar.cloud](https://docs.serviceradar.cloud)**

Documentation topics include:
- Detailed installation instructions
- Configuration guides
- Security setup (mTLS)
- SNMP polling configuration
- Network scanning
- Dusk node monitoring
- And more...

## Try it

Connect to our live-system. This instance is part of our continuous-deployment system and may contain previews of upcoming builds or features, or may not work at all.

**[https://demo.serviceradar.cloud](https://demo.serviceradar.cloud)** (admin:rb8pDYNLRDeT)

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request. Join our [Discord](https://discord.gg/dhaNgF9d3g)! 

## License

This project is licensed under the Apache 2.0 License - see the LICENSE file for details.
