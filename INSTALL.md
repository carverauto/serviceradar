# ServiceRadar Installation Guide

## Overview

ServiceRadar provides a flexible installation script (`install-serviceradar.sh`) that supports multiple deployment scenarios. The script can be run interactively or non-interactively to install various combinations of components.

## Installation Scenarios

### Interactive Installation

For guided installation, simply run:

```bash
curl -sSL https://github.com/carverauto/serviceradar/releases/download/1.0.47/install-serviceradar.sh | bash
```

Follow the prompts to select your desired components and optional checkers.

### Non-Interactive Installation

For automated deployments, use the following options:

### All-in-One Installation
Installs all components (`serviceradar-agent`, `serviceradar-core`, `serviceradar-kv`, `serviceradar-nats`, `serviceradar-poller`, `serviceradar-web`, plus optional checkers).

```bash
# Without checkers
curl -sSL https://github.com/carverauto/serviceradar/releases/download/1.0.47/install-serviceradar.sh | bash -s -- --all --non-interactive

# With checkers
curl -sSL https://github.com/carverauto/serviceradar/releases/download/1.0.47/install-serviceradar.sh | bash -s -- --all --non-interactive --checkers=rperf,snmp
```

### Core + Web UI Installation
Installs core components (`serviceradar-core`, `serviceradar-web`, `serviceradar-nats`, `serviceradar-kv`, plus optional checkers).

```bash
# Without checkers
curl -sSL https://github.com/carverauto/serviceradar/releases/download/1.0.47/install-serviceradar.sh | bash -s -- --core --non-interactive

# With checkers
curl -sSL https://github.com/carverauto/serviceradar/releases/download/1.0.47/install-serviceradar.sh | bash -s -- --core --non-interactive --checkers=dusk-checker
```

### Poller Installation
Installs the poller component (`serviceradar-poller`, plus optional checkers).

```bash
# Without checkers
curl -sSL https://github.com/carverauto/serviceradar/releases/download/1.0.47/install-serviceradar.sh | bash -s -- --poller --non-interactive

# With checkers
curl -sSL https://github.com/carverauto/serviceradar/releases/download/1.0.47/install-serviceradar.sh | bash -s -- --poller --non-interactive --checkers=rperf,snmp
```

### Agent Installation
Installs the agent component (`serviceradar-agent`, plus optional checkers).

```bash
# Without checkers
curl -sSL https://github.com/carverauto/serviceradar/releases/download/1.0.47/install-serviceradar.sh | bash -s -- --agent --non-interactive

# With checkers
curl -sSL https://github.com/carverauto/serviceradar/releases/download/1.0.47/install-serviceradar.sh | bash -s -- --agent --non-interactive --checkers=rperf,rperf-checker,snmp
```

### Combined Installation
You can combine installation scenarios by specifying multiple flags:

```bash
# Example: Poller + Agent with checkers
curl -sSL https://github.com/carverauto/serviceradar/releases/download/1.0.47/install-serviceradar.sh | bash -s -- --poller --agent --non-interactive --checkers=rperf,snmp
```

## Available Checkers

ServiceRadar supports optional checkers that extend monitoring capabilities:

- `rperf`: Network performance testing tool
- `rperf-checker`: Integration for ServiceRadar to use rperf
- `snmp`: SNMP monitoring capabilities
- `dusk-checker`: Specialized monitoring for Dusk Network nodes

## Manual Installation (Advanced)

If you prefer to manually install individual components, you can download and install the Debian packages directly:

```bash
# Download components
curl -LO https://github.com/carverauto/serviceradar/releases/download/1.0.47/serviceradar-agent_1.0.47.deb \
     -O https://github.com/carverauto/serviceradar/releases/download/1.0.47/serviceradar-poller_1.0.47.deb \
     -O https://github.com/carverauto/serviceradar/releases/download/1.0.47/serviceradar-core_1.0.47.deb \
     -O https://github.com/carverauto/serviceradar/releases/download/1.0.47/serviceradar-web_1.0.47.deb

# Install components as needed
sudo dpkg -i serviceradar-agent_1.0.47.deb serviceradar-poller_1.0.47.deb serviceradar-core_1.0.47.deb serviceradar-web_1.0.47.deb
```

## Architecture Overview

ServiceRadar uses a distributed architecture with four main components:

1. **Agent**: Runs on monitored hosts, provides service status through gRPC
2. **Poller**: Coordinates monitoring activities, can run anywhere in your network
3. **Core Service**: Receives reports from pollers, provides API, and sends alerts
4. **Web UI**: Provides a modern dashboard interface with Nginx as a reverse proxy

## Configuration

After installation, configuration files are located in `/etc/serviceradar/`. See our [documentation](https://docs.serviceradar.cloud) for detailed configuration instructions.

## Further Documentation

For comprehensive information on installation, configuration, and usage, please visit:

**[https://docs.serviceradar.cloud](https://docs.serviceradar.cloud)**