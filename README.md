<div align=center>
  
[![Website](https://img.shields.io/website?up_message=SERVICERADAR&down_message=DOWN&url=https%3A%2F%2Fserviceradar.cloud&style=for-the-badge)](https://serviceradar.cloud)
[![Demo](https://img.shields.io/website?label=Demo&up_color=blue&up_message=DEMO&down_message=DOWN&url=https%3A%2F%2Fdemo.serviceradar.cloud&style=for-the-badge)](https://demo.serviceradar.cloud)
[![Apache 2.0 License](https://img.shields.io/badge/license-Apache%202.0-blueviolet?style=for-the-badge)](https://www.apache.org/licenses/LICENSE-2.0)

</div>

# ServiceRadar

<img width="1470" height="798" alt="Screenshot 2025-08-03 at 12 15 47 AM" src="https://github.com/user-attachments/assets/d6c61754-89d7-4c56-981f-1486e0586f3a" />

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

### Option 1: Docker Compose (Recommended)

The fastest way to get ServiceRadar running is with Docker Compose. This deploys the complete stack including the database, web UI, and all monitoring services.

**Prerequisites:**
- Docker and Docker Compose installed
- 8GB+ available RAM
- Ports 80, 8090, 5423 available

```bash
# Clone the repository
git clone https://github.com/carverauto/serviceradar.git
cd serviceradar

# Start all services
docker-compose up -d

# Check status
docker-compose ps

# Bring up Kong API Gateway + NGINX
docker compose up -d nginx kong

# View logs
docker-compose logs -f web

# Get Random Generated Admin Password
docker-compose logs config-updater
```

**Access ServiceRadar:**
- **Web UI**: http://localhost (login: admin / randomPW)

**Stop Services:**
```bash
docker-compose down
```

For detailed installation options including component-specific deployments and optional checkers, see [INSTALL.md](INSTALL.md).

## Architecture Overview

ServiceRadar (SR) uses a distributed architecture with four main components:

1. **Agent** - Runs on monitored hosts, provides service status through gRPC
2. **Poller** - Coordinates monitoring activities, can run anywhere in your network
3. **Core Service** - Receives reports from pollers, provides API, and sends alerts
4. **Web UI** - Provides a modern dashboard interface with Nginx as a reverse proxy

## Docker Deployment

ServiceRadar provides a complete Docker Compose stack with all components pre-configured and ready to run.

### Services Included

The Docker Compose deployment includes:

- **Unified Database** - PostgreSQL managed by CloudNativePG with TimescaleDB (metrics) and Apache AGE (graph topology) extensions
- **Core API** - Main ServiceRadar API and business logic
- **API Gateway** - Polyglot APIs or Bring Your Own API, easily extend SR
- **Web UI** - Modern React-based dashboard
- **Nginx** - Reverse proxy and load balancer
- **Agent** - Host monitoring service
- **Poller** - Network and service polling coordinator
- **Sync Service** - Data synchronization between integrations (Armis, NetBox, etc.)
- **Data Svc (Messaging, KV, and Object Store)** - Configuration and state management
- **Observability Stack** - OTEL, logging, and telemetry collection
- **Network Discovery** - SNMP/LLDP network mapping
- **Performance Testing** - Built-in network performance monitoring

### Custom Configuration

To customize the deployment:

```bash
# Copy and modify configuration files
cp docker-compose.yml docker-compose.override.yml

# Edit configuration as needed
vim docker-compose.override.yml

# Deploy with custom config
docker-compose -f docker-compose.yml -f docker-compose.override.yml up -d
```

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
