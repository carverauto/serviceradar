# ServiceRadar

<img width="1470" height="798" alt="Screenshot 2025-08-03 at 12 15 47 AM" src="https://github.com/user-attachments/assets/d6c61754-89d7-4c56-981f-1486e0586f3a" />

[![CI](https://github.com/carverauto/serviceradar/actions/workflows/main.yml/badge.svg)](https://github.com/carverauto/serviceradar/actions/workflows/main.yml)
[![Go Linter](https://github.com/carverauto/serviceradar/actions/workflows/golangci-lint.yml/badge.svg)](https://github.com/carverauto/serviceradar/actions/workflows/golangci-lint.yml)
[![Web Linter](https://github.com/carverauto/serviceradar/actions/workflows/web-lint.yml/badge.svg)](https://github.com/carverauto/serviceradar/actions/workflows/web-lint.yml)
[![Go Tests](https://github.com/carverauto/serviceradar/actions/workflows/tests-golang.yml/badge.svg)](https://github.com/carverauto/serviceradar/actions/workflows/tests-golang.yml)
[![Rust Tests](https://github.com/carverauto/serviceradar/actions/workflows/tests-rust.yml/badge.svg)](https://github.com/carverauto/serviceradar/actions/workflows/tests-rust.yml)
[![OCaml Lint](https://github.com/carverauto/serviceradar/actions/workflows/ocaml-lint.yml/badge.svg)](https://github.com/carverauto/serviceradar/actions/workflows/ocaml-lint.yml)

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
- **Stream Processing**: Timeplus stream processing engine -- streaming OLAP w/ ClickHouse
- **Observability**: Collect metrics, logs, and traces from SNMP, OTEL, and SYSLOG
- **Network Mapper**: Discovery Engine uses SNMP/LLDP/CDP and API to discover devices, interfaces, and topology
- **Security**: Support for mTLS to secure communications between components and API key authentication for web UI
- **Rule Engine**: Blazing fast rust-based rule processing engine
- **Specialized Monitoring**: Support for specific node types like Dusk Network nodes

## Quick Installation

### Option 1: Docker Compose (Recommended)

The fastest way to get ServiceRadar running is with Docker Compose. This deploys the complete stack including the database, web UI, and all monitoring services.

**Prerequisites:**
- Docker and Docker Compose installed
- 8GB+ available RAM
- Ports 80, 8090, 8123, 9440 available

```bash
# Clone the repository
git clone https://github.com/carverauto/serviceradar.git
cd serviceradar

# Start all services
docker-compose up -d

# Check status
docker-compose ps

# View logs
docker-compose logs -f web

# Get Random Generated Admin Password
docker-compose logs config-updater
```

**Access ServiceRadar:**
- **Web UI**: http://localhost (login: admin / serviceradar2025)
- **API**: http://localhost/api/status
- **Database**: localhost:8123 (HTTP) / localhost:9440 (HTTPS)

**Stop Services:**
```bash
docker-compose down
```

### Option 2: Native Installation

ServiceRadar provides a simple installation script for deploying components natively:

```bash
# All-in-One Installation (non-interactive mode)
curl -sSL https://github.com/carverauto/serviceradar/releases/download/1.0.52/install-serviceradar.sh | bash -s -- --all --non-interactive
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

- **Proton Database** - Timeplus stream processing engine with ClickHouse compatibility
- **Core API** - Main ServiceRadar API and business logic
- **API Gateway** - Polyglot APIs or Bring Your Own API, easily extend SR
- **Web UI** - Modern React-based dashboard  
- **Nginx** - Reverse proxy and load balancer
- **Agent** - Host monitoring service
- **Poller** - Network and service polling coordinator
- **Sync Service** - Data synchronization between components
- **Key-Value Store** - Configuration and state management
- **Observability Stack** - OTEL, logging, and telemetry collection
- **Network Discovery** - SNMP/LLDP network mapping
- **Performance Testing** - Built-in network performance monitoring

### Multi-Platform Support

All Docker images are built for both **AMD64** and **ARM64** architectures, ensuring compatibility with:
- Intel/AMD servers
- Apple Silicon Macs (M1/M2/M3)
- ARM-based cloud instances
- Raspberry Pi (4GB+ recommended)

### Configuration

Default configuration includes:
- **Database**: Automatic setup with optimized settings
- **Security**: mTLS between services, API key authentication
- **Networking**: All services communicate via internal Docker network
- **Storage**: Persistent volumes for database and configuration
- **Monitoring**: Built-in health checks and metrics collection

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

ServiceRadar powered by [Timeplus Proton](https://github.com/timeplus-io/proton) can deliver 90 million EPS, 4 millisecond end-to-end latency, and high cardinality aggregation with 1 million unique keys on an Apple Macbook Pro with M2 MAX.

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

**[https://demo.serviceradar.cloud](https://demo.serviceradar.cloud)** (admin:tu3kMPfO5GZ1)

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request. Join our [Discord](https://discord.gg/dhaNgF9d3g)! 

## License

This project is licensed under the Apache 2.0 License - see the LICENSE file for details.
