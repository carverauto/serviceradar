---
sidebar_position: 2
title: Installation Guide
---

# Installation Guide

ServiceRadar components are distributed as Debian packages. Below are the recommended installation steps for a standard setup.

## Standard Setup (Recommended)

Install these components on your monitored host:

```bash
# Download and install core components
curl -LO https://github.com/mfreeman451/serviceradar/releases/download/1.0.19/serviceradar-agent_1.0.19.deb
curl -LO https://github.com/mfreeman451/serviceradar/releases/download/1.0.19/serviceradar-poller_1.0.19.deb
sudo dpkg -i serviceradar-agent_1.0.19.deb serviceradar-poller_1.0.19.deb
```

On a separate machine (recommended) or the same host for the cloud service:

```bash
curl -LO https://github.com/mfreeman451/serviceradar/releases/download/1.0.19/serviceradar-cloud_1.0.19.deb
sudo dpkg -i serviceradar-cloud_1.0.19.deb
```

## Optional Components

### SNMP Polling

For collecting and visualizing metrics:

```bash
curl -LO https://github.com/mfreeman451/serviceradar/releases/download/1.0.19/serviceradar-snmp-checker_1.0.19.deb
sudo dpkg -i serviceradar-snmp-checker_1.0.19.deb
```

### Dusk Node Monitoring

For specialized monitoring of Dusk nodes:

```bash
curl -LO https://github.com/mfreeman451/serviceradar/releases/download/1.0.19/serviceradar-agent_1.0.19.deb
sudo dpkg -i serviceradar-agent_1.0.19.deb
```

## Distributed Setup

For larger deployments, install components on separate hosts:

1. On monitored hosts:

```bash
curl -LO https://github.com/mfreeman451/serviceradar/releases/download/1.0.19/serviceradar-agent_1.0.19.deb
sudo dpkg -i serviceradar-agent_1.0.19.deb
```

2. On monitoring host:

```bash
curl -LO https://github.com/mfreeman451/serviceradar/releases/download/1.0.19/serviceradar-poller_1.0.19.deb
sudo dpkg -i serviceradar-poller_1.0.19.deb
```

3. On cloud host:

```bash
curl -LO https://github.com/mfreeman451/serviceradar/releases/download/1.0.19/serviceradar-cloud_1.0.19.deb
sudo dpkg -i serviceradar-cloud_1.0.19.deb
```