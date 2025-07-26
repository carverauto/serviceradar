# ServiceRadar

<img width="1470" height="797" alt="Screenshot 2025-07-25 at 1 53 45 AM" src="https://github.com/user-attachments/assets/8b981c02-1683-480f-a003-b7af71f7c36e" />

[![releases](https://github.com/carverauto/serviceradar/actions/workflows/release.yml/badge.svg)](https://github.com/carverauto/serviceradar/actions/workflows/release.yml)
[![Go Linter](https://github.com/carverauto/serviceradar/actions/workflows/golangci-lint.yml/badge.svg)](https://github.com/carverauto/serviceradar/actions/workflows/golangci-lint.yml)
[![Web Linter](https://github.com/carverauto/serviceradar/actions/workflows/web-lint.yml/badge.svg)](https://github.com/carverauto/serviceradar/actions/workflows/web-lint.yml)
[![Go Tests](https://github.com/carverauto/serviceradar/actions/workflows/tests-golang.yml/badge.svg)](https://github.com/carverauto/serviceradar/actions/workflows/tests-golang.yml)
[![Rust Tests](https://github.com/carverauto/serviceradar/actions/workflows/tests-rust.yml/badge.svg)](https://github.com/carverauto/serviceradar/actions/workflows/tests-rust.yml)
<a href="https://cla-assistant.io/carverauto/serviceradar"><img src="https://cla-assistant.io/readme/badge/carverauto/serviceradar" alt="CLA assistant" /></a>

ServiceRadar is a distributed network monitoring system designed for infrastructure and services in hard to reach places or constrained environments.
It provides real-time monitoring of internal services, with cloud-based alerting capabilities to ensure you stay informed even during network or power outages.

## Features

- **Real-time Monitoring**: Monitor services and infrastructure in hard-to-reach places
- **Distributed Architecture**: Components can be installed across different hosts to suit your needs
- **Stream Processing**: Timeplus stream processing engine -- streaming OLAP w/ ClickHouse
- **Observability**: Collect metrics, logs, and traces from SNMP, OTEL, and SYSLOG
- **Network Mapper**: Discovery Engine uses SNMP/LLDP/CDP and API to discover devices, interfaces, and topology
- **Security**: Support for mTLS to secure communications between components and API key authentication for web UI
- **Rule Engine**: Blazing fast rust-based rule processing engine
- **Specialized Monitoring**: Support for specific node types like Dusk Network nodes

## Quick Installation

ServiceRadar provides a simple installation script for deploying all components:

```bash
# All-in-One Installation (non-interactive mode)
curl -sSL https://github.com/carverauto/serviceradar/releases/download/1.0.48/install-serviceradar.sh | bash -s -- --all --non-interactive
```

For detailed installation options including component-specific deployments and optional checkers, see [INSTALL.md](INSTALL.md).

## Architecture Overview

ServiceRadar uses a distributed architecture with four main components:

1. **Agent** - Runs on monitored hosts, provides service status through gRPC
2. **Poller** - Coordinates monitoring activities, can run anywhere in your network
3. **Core Service** - Receives reports from pollers, provides API, and sends alerts
4. **Web UI** - Provides a modern dashboard interface with Nginx as a reverse proxy

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

**[https://demo.serviceradar.cloud](https://demo.serviceradar.cloud)**

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the Apache 2.0 License - see the LICENSE file for details.
