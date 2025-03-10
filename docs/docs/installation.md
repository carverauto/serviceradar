---
sidebar_position: 2
title: Installation Guide
---

# Installation Guide for Debian Linux

ServiceRadar components are distributed as Debian packages. Below are the recommended installation steps for different deployment scenarios.

## Standard Setup (Recommended)

Install these components on your monitored host:

```bash
# Download and install agent and poller components
curl -LO https://github.com/carverauto/serviceradar/releases/download/1.0.22/serviceradar-agent_1.0.22.deb \
     -O https://github.com/carverauto/serviceradar/releases/download/1.0.22/serviceradar-poller_1.0.22.deb

sudo dpkg -i serviceradar-agent_1.0.22.deb serviceradar-poller_1.0.22.deb
```

On a separate machine (recommended) or the same host for the core service:

```bash
# Download and install core service
curl -LO https://github.com/carverauto/serviceradar/releases/download/1.0.22/serviceradar-core_1.0.22.deb
sudo dpkg -i serviceradar-core_1.0.22.deb
```

To install the web UI (dashboard):

```bash
# Download and install web UI
curl -LO https://github.com/carverauto/serviceradar/releases/download/1.0.22/serviceradar-web_1.0.22.deb
sudo dpkg -i serviceradar-web_1.0.22.deb
```

## Optional Components

## SNMP Polling

For collecting and visualizing metrics from network devices:

```bash
curl -LO https://github.com/carverauto/serviceradar/releases/download/1.0.22/serviceradar-snmp-checker_1.0.22.deb
sudo dpkg -i serviceradar-snmp-checker_1.0.22.deb
```

## Dusk Node Monitoring

For specialized monitoring of [Dusk Network](https://dusk.network/) nodes:

```bash
curl -LO https://github.com/carverauto/serviceradar/releases/download/1.0.22/serviceradar-dusk-checker_1.0.22.deb
sudo dpkg -i serviceradar-dusk-checker_1.0.22.deb
```

## Distributed Setup

For larger deployments, install components on separate hosts:

1. **On monitored hosts** (install only the agent):

```bash
curl -LO https://github.com/carverauto/serviceradar/releases/download/1.0.22/serviceradar-agent_1.0.22.deb
sudo dpkg -i serviceradar-agent_1.0.22.deb
```

2. **On monitoring host** (install the poller):

```bash
curl -LO https://github.com/carverauto/serviceradar/releases/download/1.0.22/serviceradar-poller_1.0.22.deb
sudo dpkg -i serviceradar-poller_1.0.22.deb
```

3. **On core host** (install the core service):

```bash
curl -LO https://github.com/carverauto/serviceradar/releases/download/1.0.22/serviceradar-core_1.0.22.deb
sudo dpkg -i serviceradar-core_1.0.22.deb
```

## Verification

After installation, verify the services are running:

```bash
# Check agent status
systemctl status serviceradar-agent

# Check poller status
systemctl status serviceradar-poller

# Check core status
systemctl status serviceradar-core
```

## Firewall Configuration

If you're using UFW (Ubuntu's Uncomplicated Firewall), add these rules:

```bash
# On agent hosts
sudo ufw allow 50051/tcp  # For agent gRPC server
sudo ufw allow 50052/tcp  # For Dusk checker (if applicable)

# On core host
sudo ufw allow 50052/tcp  # For poller connections
sudo ufw allow 8090/tcp   # For API (internal use)

# If running web UI
sudo ufw allow 80/tcp     # For web interface
```

# ServiceRadar Installation Guide for Oracle Linux/RHEL

This guide covers the installation and configuration of ServiceRadar components on Oracle Linux and RHEL-based systems.

## Prerequisites

Before installing ServiceRadar, ensure your system meets the following requirements:

## System Requirements
- Oracle Linux 9 / RHEL 9 or compatible distribution
- System user with sudo or root access
- Minimum 2GB RAM
- Minimum 10GB disk space

### Required Packages
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

# Installation Guide for RedHat Linux based systems

## 1. Download the RPM packages

Download the latest ServiceRadar RPM packages from the releases page:

```bash
curl -LO https://github.com/carverauto/serviceradar/releases/download/1.0.22/serviceradar-core-1.0.22-1.el9.x86_64.rpm
curl -LO https://github.com/carverauto/serviceradar/releases/download/1.0.22/serviceradar-web-1.0.22-1.el9.x86_64.rpm
curl -LO https://github.com/carverauto/serviceradar/releases/download/1.0.22/serviceradar-agent-1.0.22-1.el9.x86_64.rpm
curl -LO https://github.com/carverauto/serviceradar/releases/download/1.0.22/serviceradar-poller-1.0.22-1.el9.x86_64.rpm
```

## 2. Install Core Service

The core service provides the central API and database for ServiceRadar:

```bash
sudo dnf install -y ./serviceradar-core-1.0.22-1.el9.x86_64.rpm
```

## 3. Install Web UI

The web UI provides a dashboard interface:

```bash
sudo dnf install -y ./serviceradar-web-1.0.22-1.el9.x86_64.rpm
```

## 4. Install Agent and Poller

On each monitored host:

```bash
sudo dnf install -y ./serviceradar-agent-1.0.22-1.el9.x86_64.rpm
sudo dnf install -y ./serviceradar-poller-1.0.22-1.el9.x86_64.rpm
```

# Post-Installation Configuration

## Firewall Configuration

The installation process should automatically configure the firewall, but you can verify or manually configure it:

```bash
# Check firewall status
sudo firewall-cmd --list-all

# If needed, manually open required ports
sudo firewall-cmd --permanent --add-port=80/tcp
sudo firewall-cmd --permanent --add-port=8090/tcp
sudo firewall-cmd --permanent --add-port=3000/tcp
sudo firewall-cmd --permanent --add-port=50051/tcp
sudo firewall-cmd --permanent --add-port=50052/tcp
sudo firewall-cmd --permanent --add-port=50053/tcp
sudo firewall-cmd --reload
```

## SELinux Configuration

The installation should configure SELinux automatically. If you encounter issues, you can verify or manually configure it:

```bash
# Check SELinux status
getenforce

# Allow HTTP connections (for Nginx)
sudo setsebool -P httpd_can_network_connect 1

# Configure port types
sudo semanage port -a -t http_port_t -p tcp 8090 || sudo semanage port -m -t http_port_t -p tcp 8090
sudo semanage port -a -t http_port_t -p tcp 3000 || sudo semanage port -m -t http_port_t -p tcp 3000
```

## Verify Services

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
```

## Accessing the Dashboard

After installation, you can access the ServiceRadar dashboard at:

```
http://your-server-ip/
```

# Troubleshooting

## Service Won't Start

If a service fails to start, check the logs:

```bash
# Check core service logs
sudo journalctl -xeu serviceradar-core

# Check web UI logs
sudo journalctl -xeu serviceradar-web

# Check Nginx logs
sudo cat /var/log/nginx/error.log
sudo cat /var/log/nginx/serviceradar-web.error.log
```

## SELinux Issues

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

## Nginx Connection Issues

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

## Node.js Issues

If the web UI service fails with Node.js errors:

```bash
# Check Node.js version
node --version

# Ensure NodeJS 20 is enabled
sudo dnf module list nodejs
sudo dnf module enable -y nodejs:20
sudo dnf install -y nodejs
```

## Uninstallation

If needed, you can uninstall ServiceRadar components:

```bash
sudo dnf remove -y serviceradar-core serviceradar-web serviceradar-agent serviceradar-poller
```

---

For additional help and documentation, please refer to the [ServiceRadar Documentation](https://docs.serviceradar.io/).

## Next Steps

After installation, proceed to:

1. [Configuration Basics](./configuration.md) to configure your components
2. [TLS Security](./tls-security.md) to secure communications between components