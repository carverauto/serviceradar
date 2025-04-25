---
sidebar_position: 2
title: Installation Guide
---

# Installation Guide

ServiceRadar components are distributed as Debian packages for Ubuntu/Debian systems and RPM packages for RHEL/Oracle Linux systems. Below are the recommended installation steps for different deployment scenarios.

## Debian/Ubuntu Installation

### Standard Setup (Recommended)

Install these components on your monitored host:

```bash
# Download and install agent and poller components
curl -LO https://github.com/carverauto/serviceradar/releases/download/1.0.34/serviceradar-agent_1.0.34.deb \
     -O https://github.com/carverauto/serviceradar/releases/download/1.0.34/serviceradar-poller_1.0.34.deb

sudo dpkg -i serviceradar-agent_1.0.34.deb serviceradar-poller_1.0.34.deb
```

On a separate machine (recommended) or the same host for the core service:

```bash
# Download and install core service
curl -LO https://github.com/carverauto/serviceradar/releases/download/1.0.34/serviceradar-core_1.0.34.deb
sudo dpkg -i serviceradar-core_1.0.34.deb
```

To install the web UI (dashboard):

```bash
# Download and install web UI
curl -LO https://github.com/carverauto/serviceradar/releases/download/1.0.34/serviceradar-web_1.0.34.deb
sudo dpkg -i serviceradar-web_1.0.34.deb
```

### Optional Components

#### NATS JetStream for KV Store (Optional)

ServiceRadar can use NATS JetStream as a key-value (KV) store for dynamic configuration management,
enabling real-time updates without service restarts.

##### Installing NATS with ServiceRadar

The `serviceradar-nats` package provides everything needed for NATS JetStream including the NATS server binary,
configuration files, systemd service, and appropriate directory setup:

```bash
# Download and install the serviceradar-nats package (Debian/Ubuntu)
curl -LO https://github.com/carverauto/serviceradar/releases/download/1.0.34/serviceradar-nats_1.0.34.deb
sudo dpkg -i serviceradar-nats_1.0.34.deb
```

The serviceradar-nats package automatically:
* Installs the NATS Server binary in `/usr/bin/nats-server`
* Creates a configuration file at `/etc/nats/nats-server.conf` with mTLS enabled
* Sets up a hardened systemd service (`serviceradar-nats.service`) to manage the NATS Server
* Creates necessary directories (`/var/lib/nats/jetstream` for JetStream data, `/var/log/nats` for logs)
* Creates and configures the nats user with appropriate permissions
* Configures the nats user to access ServiceRadar certificates if available

Verify the NATS Server is running:

```bash
sudo systemctl status serviceradar-nats
```

##### Install ServiceRadar KV Service

To enable the KV store functionality in ServiceRadar, install the `serviceradar-kv` package:

```bash
curl -LO https://github.com/carverauto/serviceradar/releases/download/1.0.34/serviceradar-kv_1.0.34.deb
sudo dpkg -i serviceradar-kv_1.0.34.deb
```

#### SNMP Monitoring

For collecting and visualizing metrics from network devices:

```bash
curl -LO https://github.com/carverauto/serviceradar/releases/download/1.0.34/serviceradar-snmp-checker_1.0.34.deb
sudo dpkg -i serviceradar-snmp-checker_1.0.34.deb
```

#### rperf Network Performance Monitoring

For monitoring network throughput and reliability:

```bash
# Debian/Ubuntu
curl -LO https://github.com/mfreeman451/rperf/releases/download/v1.0.34/serviceradar-rperf_1.0.34.deb
curl -LO https://github.com/mfreeman451/rperf/releases/download/v1.0.34/serviceradar-rperf-checker_1.0.34.deb
sudo dpkg -i serviceradar-rperf_1.0.34.deb serviceradar-rperf-checker_1.0.34.deb

# RHEL/Oracle Linux
curl -LO https://github.com/mfreeman451/rperf/releases/download/v1.0.34/serviceradar-rperf-1.0.34.el9.x86_64.rpm
curl -LO https://github.com/mfreeman451/rperf/releases/download/v1.0.34/serviceradar-rperf-checker-1.0.34.el9.x86_64.rpm
sudo dnf install -y ./serviceradar-rperf-1.0.34.el9.x86_64.rpm ./serviceradar-rperf-checker-1.0.34.el9.x86_64.rpm
```

- Server: Install serviceradar-rperf on a reflector host.
- Client: Install serviceradar-rperf-checker on the Agent host for testing.

Update the "Firewall Configuration" section:

# Additional rules for rperf
```bash
sudo ufw allow 5199/tcp  # rperf server control port
sudo ufw allow 5200:5210/tcp  # rperf data ports (if using port pool)
sudo ufw allow from 192.168.2.23 to any port 5199 proto udp # rperf server control port (UDP)
sudo ufw allow from 192.168.2.23 to any port 5200:5210 proto udp # rperf data ports (UDP)
sudo ufw allow 50081/tcp  # rperf-grpc client
```

#### Dusk Node Monitoring

For specialized monitoring of [Dusk Network](https://dusk.network/) nodes:

```bash
curl -LO https://github.com/carverauto/serviceradar/releases/download/1.0.34/serviceradar-dusk-checker_1.0.34.deb
sudo dpkg -i serviceradar-dusk-checker_1.0.34.deb
```

### Distributed Setup

For larger deployments, install components on separate hosts:

1. **On monitored hosts** (install only the agent):

```bash
curl -LO https://github.com/carverauto/serviceradar/releases/download/1.0.34/serviceradar-agent_1.0.34.deb
sudo dpkg -i serviceradar-agent_1.0.34.deb
```

2. **On monitoring host** (install the poller):

```bash
curl -LO https://github.com/carverauto/serviceradar/releases/download/1.0.34/serviceradar-poller_1.0.34.deb
sudo dpkg -i serviceradar-poller_1.0.34.deb
```

3. **On core host** (install the core service):

```bash
curl -LO https://github.com/carverauto/serviceradar/releases/download/1.0.34/serviceradar-core_1.0.34.deb
sudo dpkg -i serviceradar-core_1.0.34.deb
```

### Verification

After installation, verify the services are running:

```bash
# Check agent status
systemctl status serviceradar-agent

# Check poller status
systemctl status serviceradar-poller

# Check core status
systemctl status serviceradar-core

# Check NATS Server status (if installed)
systemctl status nats

# Check KV service status (if installed)
systemctl status serviceradar-kv
```

### Firewall Configuration

If you're using UFW (Ubuntu's Uncomplicated Firewall), add these rules:

```bash
# On agent hosts
sudo ufw allow 50051/tcp  # For agent gRPC server
sudo ufw allow 50080/tcp  # For SNMP (poller) checker (if applicable)
sudo ufw allow 50081/tcp  # For RPerf checker (if applicable)
sudo ufw allow 50082/tcp  # For Dusk checker (if applicable)

# On core host
sudo ufw allow 50052/tcp  # For poller connections
sudo ufw allow 8090/tcp   # For API (internal use)

# If running web UI
sudo ufw allow 80/tcp     # For web interface

# If using NATS JetStream for KV store
sudo ufw allow 50054/tcp  # For serviceradar-kv gRPC service
```

> **Security Note:** By default, NATS Server is configured to listen only on 127.0.0.1 (localhost), so port 4222 does not need to be opened in the firewall. The Next.js service (port 3000) is also not exposed externally as Nginx (port 80) proxies requests to it.

### SELinux Configuration (if enabled)

If you have SELinux enabled on your Debian/Ubuntu system:

```bash
# Allow HTTP connections (for Nginx)
sudo setsebool -P httpd_can_network_connect 1

# Configure port types
sudo semanage port -a -t http_port_t -p tcp 8090 || sudo semanage port -m -t http_port_t -p tcp 8090
sudo semanage port -a -t unreserved_port_t -p tcp 50054 || sudo semanage port -m -t unreserved_port_t -p tcp 50054
```

## RHEL/Oracle Linux Installation

This guide covers the installation and configuration of ServiceRadar components on Oracle Linux and RHEL-based systems.

### Prerequisites

Before installing ServiceRadar, ensure your system meets the following requirements:

#### System Requirements
- Oracle Linux 9 / RHEL 9 or compatible distribution
- System user with sudo or root access
- Minimum 2GB RAM
- Minimum 10GB disk space

#### Required Packages
The following packages will be automatically installed as dependencies, but you can install them manually if needed:

```bash
# Install EPEL repository
sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm

# Enable CodeReady Builder repository (Oracle Linux only)
sudo dnf config-manager --set-enabled ol9_codeready_builder

# Install Node.js 20
sudo dnf module enable -y nodejs:20
sudo dnf install -y nodejs

# Install Nginx
sudo dnf install -y nginx
```

### Standard Setup (Recommended)

#### 1. Download the RPM packages

Download the latest ServiceRadar RPM packages from the releases page:

```bash
curl -LO https://github.com/carverauto/serviceradar/releases/download/1.0.34/serviceradar-core-1.0.34-1.el9.x86_64.rpm
curl -LO https://github.com/carverauto/serviceradar/releases/download/1.0.34/serviceradar-web-1.0.34-1.el9.x86_64.rpm
curl -LO https://github.com/carverauto/serviceradar/releases/download/1.0.34/serviceradar-agent-1.0.34-1.el9.x86_64.rpm
curl -LO https://github.com/carverauto/serviceradar/releases/download/1.0.34/serviceradar-poller-1.0.34-1.el9.x86_64.rpm
```

#### 2. Install Core Service

The core service provides the central API and database for ServiceRadar:

```bash
sudo dnf install -y ./serviceradar-core-1.0.34-1.el9.x86_64.rpm
```

#### 3. Install Web UI

The web UI provides a dashboard interface:

```bash
sudo dnf install -y ./serviceradar-web-1.0.34-1.el9.x86_64.rpm
```

#### 4. Install Agent and Poller

On each monitored host:

```bash
sudo dnf install -y ./serviceradar-agent-1.0.34-1.el9.x86_64.rpm
sudo dnf install -y ./serviceradar-poller-1.0.34-1.el9.x86_64.rpm
```

### Distributed Setup

For larger deployments, install components on separate hosts:

1. **On monitored hosts** (install only the agent):

```bash
curl -LO https://github.com/carverauto/serviceradar/releases/download/1.0.34/serviceradar-agent-1.0.34-1.el9.x86_64.rpm
sudo dnf install -y ./serviceradar-agent-1.0.34-1.el9.x86_64.rpm
```

2. **On monitoring host** (install the poller):

```bash
curl -LO https://github.com/carverauto/serviceradar/releases/download/1.0.34/serviceradar-poller-1.0.34-1.el9.x86_64.rpm
sudo dnf install -y ./serviceradar-poller-1.0.34-1.el9.x86_64.rpm
```

3. **On core host** (install the core service):

```bash
curl -LO https://github.com/carverauto/serviceradar/releases/download/1.0.34/serviceradar-core-1.0.34-1.el9.x86_64.rpm
sudo dnf install -y ./serviceradar-core-1.0.34-1.el9.x86_64.rpm
```

### Optional Components

#### Install NATS Server for KV Store (Optional)

If you plan to use NATS JetStream as a KV store for dynamic configuration:

##### Step 1: Install the NATS Server with `serviceradar-nats`

The `serviceradar-nats` package provides the necessary configuration files, systemd service, and directory setup to enable
NATS Server to start automatically with mTLS enabled.

```bash
# Download and install the serviceradar-nats package
curl -LO https://github.com/carverauto/serviceradar/releases/download/1.0.34/serviceradar-nats-1.0.34-1.el9.x86_64.rpm
sudo dnf install -y ./serviceradar-nats-1.0.34-1.el9.x86_64.rpm
```

The serviceradar-nats package automatically:
* Installs the NATS Server binary in `/usr/bin/nats-server`
* Creates a configuration file at `/etc/nats/nats-server.conf` with mTLS enabled
* Sets up a hardened systemd service (nats.service) to manage the NATS Server
* Creates necessary directories (`/var/lib/nats/jetstream` for JetStream data, `/var/log/nats` for logs)
* Configures permissions for the nats user

Verify the NATS Server is running:

```bash
sudo systemctl status nats
```

##### Install ServiceRadar KV Service

To enable the KV store functionality:

```bash
curl -LO https://github.com/carverauto/serviceradar/releases/download/1.0.34/serviceradar-kv-1.0.34-1.el9.x86_64.rpm
sudo dnf install -y ./serviceradar-kv-1.0.34-1.el9.x86_64.rpm
```

> **Security Note:** By default, the NATS Server is configured to listen only on the loopback interface (127.0.0.1) for security, preventing external network access. ServiceRadar's KV service communicates with NATS Server locally, so you don't need to open port 4222 in your firewall unless NATS Server needs to be accessed from other hosts. This configuration significantly enhances the security of your deployment.

#### SNMP Monitoring and Dusk Node Monitoring

For specialized monitoring capabilities:

```bash
# SNMP Checker for network device monitoring
curl -LO https://github.com/carverauto/serviceradar/releases/download/1.0.34/serviceradar-snmp-checker-1.0.34-1.el9.x86_64.rpm
sudo dnf install -y ./serviceradar-snmp-checker-1.0.34-1.el9.x86_64.rpm

# Dusk Node Checker for Dusk Network monitoring
curl -LO https://github.com/carverauto/serviceradar/releases/download/1.0.34/serviceradar-dusk-checker-1.0.34-1.el9.x86_64.rpm
sudo dnf install -y ./serviceradar-dusk-checker-1.0.34-1.el9.x86_64.rpm
```

### Post-Installation Configuration

#### Firewall Configuration

The installation process should automatically configure the firewall, but you can verify or manually configure it:

```bash
# Check firewall status
sudo firewall-cmd --list-all

# If needed, manually open required ports
sudo firewall-cmd --permanent --add-port=80/tcp      # Web UI
sudo firewall-cmd --permanent --add-port=8090/tcp    # Core API
sudo firewall-cmd --permanent --add-port=50051/tcp   # Agent
sudo firewall-cmd --permanent --add-port=50052/tcp   # Core gRPC / Dusk Checker
sudo firewall-cmd --permanent --add-port=50053/tcp   # Poller
sudo firewall-cmd --permanent --add-port=50057/tcp   # serviceradar-kv
sudo firewall-cmd --permanent --add-port=50058/tcp   # serviceradar-sync
sudo firewall-cmd --reload
```

> **Security Note:** Port 4222 (NATS) is not included in the firewall rules as the NATS Server is configured to listen only on 127.0.0.1 (localhost) by default. Port 3000 (Next.js) is also not exposed externally as Nginx (port 80) proxies requests to it.

#### SELinux Configuration

The installation should configure SELinux automatically. If you encounter issues, you can verify or manually configure it:

```bash
# Check SELinux status
getenforce

# Allow HTTP connections (for Nginx)
sudo setsebool -P httpd_can_network_connect 1

# Configure port types
sudo semanage port -a -t http_port_t -p tcp 8090 || sudo semanage port -m -t http_port_t -p tcp 8090
sudo semanage port -a -t unreserved_port_t -p tcp 50054 || sudo semanage port -m -t unreserved_port_t -p tcp 50054
sudo semanage port -a -t unreserved_port_t -p tcp 4222 || sudo semanage port -m -t unreserved_port_t -p tcp 4222
```

### Verify Services

Check that all services are running correctly:

```bash
# Check core service
sudo systemctl status serviceradar-core

# Check web UI service
sudo systemctl status serviceradar-web

# Check Nginx
sudo systemctl status nginx

# Check agent (on monitored host)
sudo systemctl status serviceradar-agent

# Check poller (on monitored host)
sudo systemctl status serviceradar-poller

# Check NATS Server (if installed)
sudo systemctl status nats

# Check KV service (if installed)
sudo systemctl status serviceradar-kv
```

### Accessing the Dashboard

After installation, you can access the ServiceRadar dashboard at:

```
http://your-server-ip/
```

## Troubleshooting

### Service Won't Start

If a service fails to start, check the logs:

```bash
# Check core service logs
sudo journalctl -xeu serviceradar-core

# Check web UI logs
sudo journalctl -xeu serviceradar-web

# Check Nginx logs
sudo cat /var/log/nginx/error.log
sudo cat /var/log/nginx/serviceradar-web.error.log

# Check NATS Server logs (if installed)
sudo cat /var/log/nats/nats.log
```

### Node.js Issues (Web UI)

If the web UI service fails with Node.js errors:

```bash
# Check Node.js version
node --version

# For Debian/Ubuntu
sudo apt install -y nodejs npm

# For RHEL/Oracle Linux
sudo dnf module enable -y nodejs:20
sudo dnf install -y nodejs
```

### SELinux Issues (RHEL/Oracle Linux)

If you encounter SELinux-related issues:

```bash
# View SELinux denials
sudo ausearch -m avc --start recent

# Temporarily set SELinux to permissive mode for testing
sudo setenforce 0

# Create a custom policy module
sudo ausearch -m avc -c nginx 2>&1 | audit2allow -M serviceradar-nginx
sudo semodule -i serviceradar-nginx.pp
```

### Nginx Connection Issues

If Nginx can't connect to the backend services:

```bash
# Test direct connection to API
curl http://localhost:8090/api/status

# Test direct connection to Next.js
curl http://localhost:3000

# Check API key
sudo cat /etc/serviceradar/api.env

# Ensure proper permissions on API key file
sudo chmod 644 /etc/serviceradar/api.env
sudo chown serviceradar:serviceradar /etc/serviceradar/api.env
```

### NATS Connection Issues

If the `serviceradar-kv` service cannot connect to NATS:

```bash
# Check NATS Server logs
sudo cat /var/log/nats/nats.log

# Test NATS connection
nats server check --server nats://localhost:4222

# Verify certificates are in place
ls -la /etc/serviceradar/certs/
```

### Uninstallation

If needed, you can uninstall ServiceRadar components:

#### Debian/Ubuntu:
```bash
sudo apt remove -y serviceradar-core serviceradar-web serviceradar-agent serviceradar-poller
sudo apt remove -y serviceradar-nats serviceradar-kv
sudo apt remove -y nats-server
```

#### RHEL/Oracle Linux:
```bash
sudo dnf remove -y serviceradar-core serviceradar-web serviceradar-agent serviceradar-poller
sudo dnf remove -y serviceradar-nats serviceradar-kv
sudo dnf remove -y nats-server
```

## Next Steps

After installation, proceed to:

1. [Configuration Basics](./configuration.md) to configure your components
2. [TLS Security](./tls-security.md) to secure communications between components