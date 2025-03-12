# ServiceRadar

[![releases](https://github.com/carverauto/serviceradar/actions/workflows/release.yml/badge.svg)](https://github.com/carverauto/serviceradar/actions/workflows/release.yml)
[![linter](https://github.com/carverauto/serviceradar/actions/workflows/golangci-lint.yml/badge.svg)](https://github.com/carverauto/serviceradar/actions/workflows/golangci-lint.yml)
[![tests](https://github.com/carverauto/serviceradar/actions/workflows/tests.yml/badge.svg)](https://github.com/carverauto/serviceradar/actions/workflows/tests.yml)
[![coverage](https://github.com/carverauto/serviceradar/actions/workflows/go-coverage.yml/badge.svg)](https://github.com/carverauto/serviceradar/actions/workflows/go-coverage.yml)
<a href="https://cla-assistant.io/carverauto/serviceradar"><img src="https://cla-assistant.io/readme/badge/carverauto/serviceradar" alt="CLA assistant" /></a>

ServiceRadar is a distributed network monitoring system designed for infrastructure and services in hard to reach places or constrained environments.
It provides real-time monitoring of internal services, with cloud-based alerting capabilities to ensure you stay informed even during network or power outages.

## Features

- **Real-time Monitoring**: Monitor services and infrastructure in hard-to-reach places
- **Distributed Architecture**: Components can be installed across different hosts to suit your needs
- **SNMP Integration**: Collect and visualize network metrics
- **Security**: Support for mTLS to secure communications between components and API key authentication for web UI
- **Alerting**: Webhook-based alerts (Discord, etc.) to notify you of issues
- **Specialized Monitoring**: Support for specific node types like Dusk Network nodes

## Quick Installation

ServiceRadar can be installed via direct downloads from GitHub releases:

```bash
# Download and install core components
curl -LO https://github.com/carverauto/serviceradar/releases/download/1.0.24/serviceradar-agent_1.0.24.deb \
     -O https://github.com/carverauto/serviceradar/releases/download/1.0.24/serviceradar-poller_1.0.24.deb \
     -O https://github.com/carverauto/serviceradar/releases/download/1.0.24/serviceradar-core_1.0.24.deb \
     -O https://github.com/carverauto/serviceradar/releases/download/1.0.24/serviceradar-web_1.0.24.deb

# Install components as needed
sudo dpkg -i serviceradar-agent_1.0.24.deb serviceradar-poller_1.0.24.deb serviceradar-core_1.0.24.deb serviceradar-web_1.0.24.deb
```

## Architecture Overview

ServiceRadar uses a distributed architecture with four main components:

1. **Agent** - Runs on monitored hosts, provides service status through gRPC
2. **Poller** - Coordinates monitoring activities, can run anywhere in your network
3. **Core Service** - Receives reports from pollers, provides API, and sends alerts
4. **Web UI** - Provides a modern dashboard interface with Nginx as a reverse proxy

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
