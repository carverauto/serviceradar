---
sidebar_position: 3
title: Configuration Basics
---

# Configuration Basics

ServiceRadar components are configured via JSON files in `/etc/serviceradar/`. This guide covers the essential configurations needed to get your monitoring system up and running.

## Agent Configuration

The agent runs on each monitored host and collects status information from services.

Edit `/etc/serviceradar/agent.json`:

```json
{
  "checkers_dir": "/etc/serviceradar/checkers",
  "listen_addr": ":50051",
  "service_type": "grpc",
  "service_name": "AgentService",
  "security": {
    "mode": "none",
    "cert_dir": "/etc/serviceradar/certs",
    "server_name": "changeme",
    "role": "agent"
  }
}
```

> **Note:** Replace `"server_name": "changeme"` with the actual hostname or IP address of the poller that will connect to this agent when using mTLS security mode.

### Configuration Options:

- `checkers_dir`: Directory containing checker configurations
- `listen_addr`: Address and port the agent listens on
- `service_type`: Type of service (should be "grpc")
- `service_name`: Name of the service (should be "AgentService")
- `security`: Security settings
  - `mode`: Security mode ("none" or "mtls")
  - `cert_dir`: Directory for TLS certificates
  - `server_name`: Hostname/IP of the poller (important for TLS)
  - `role`: Role of this component ("agent")

## Poller Configuration

The poller contacts agents to collect monitoring data and reports to the core service.

Edit `/etc/serviceradar/poller.json`:

```json
{
  "agents": {
    "local-agent": {
      "address": "localhost:50051",
      "security": { 
        "server_name": "changeme", 
        "mode": "none" 
      },
      "checks": [
        { "service_type": "process", "service_name": "nginx", "details": "nginx" },
        { "service_type": "port", "service_name": "SSH", "details": "127.0.0.1:22" },
        { "service_type": "icmp", "service_name": "ping", "details": "8.8.8.8" }
      ]
    }
  },
  "core_address": "changeme:50052",
  "listen_addr": ":50053",
  "poll_interval": "30s",
  "poller_id": "my-poller",
  "service_name": "PollerService",
  "service_type": "grpc",
  "security": {
    "mode": "none",
    "cert_dir": "/etc/serviceradar/certs",
    "server_name": "changeme",
    "role": "poller"
  }
}
```

> **Note:** Replace "server_name": "changeme" in both the agents and top-level security sections with the hostname or IP address of the agent and core service, respectively. Also, replace "core_address": "changeme:50052" with the actual hostname or IP address of your core service.

### Configuration Options:

- `agents`: Map of agents to monitor
  - `address`: Network address of the agent (host:port format)
  - `security`: Security settings for connecting to this agent
  - `checks`: List of service checks to perform on this agent
- `core_address`: Address of the core service (host:port format)
- `listen_addr`: Address and port the poller listens on
- `poll_interval`: How often to poll agents (in Go duration format, e.g., "30s", "1m")
- `poller_id`: Unique identifier for this poller (must match an entry in core's known_pollers)
- `service_name`: Name of the service (should be "PollerService")
- `service_type`: Type of service (should be "grpc")
- `security`: Security settings for connecting to the core service

### Check Types:

- `process`: Check if a process is running
- `port`: Check if a TCP port is responding
- `icmp`: Ping a host
- `grpc`: Check a gRPC service
- `snmp`: Check via SNMP (requires snmp checker)
- `sweep`: Network sweep check

## Core Configuration

The core service receives reports from pollers and provides the API backend.

Edit `/etc/serviceradar/core.json`:

```json
{
  "listen_addr": ":8090",
  "grpc_addr": ":50052",
  "alert_threshold": "5m",
  "known_pollers": ["my-poller"],
  "metrics": {
    "enabled": true,
    "retention": 100,
    "max_nodes": 10000
  },
  "security": {
    "mode": "none",
    "cert_dir": "/etc/serviceradar/certs",
    "role": "core"
  },
  "webhooks": [
    {
      "enabled": false,
      "url": "https://your-webhook-url",
      "cooldown": "15m",
      "headers": [
        {
          "key": "Authorization",
          "value": "Bearer your-token"
        }
      ]
    },
    {
      "enabled": true,
      "url": "https://discord.com/api/webhooks/changeme",
      "cooldown": "15m",
      "template": "{\"embeds\":[{\"title\":\"{{.alert.Title}}\",\"description\":\"{{.alert.Message}}\",\"color\":{{if eq .alert.Level \"error\"}}15158332{{else if eq .alert.Level \"warning\"}}16776960{{else}}3447003{{end}},\"timestamp\":\"{{.alert.Timestamp}}\",\"fields\":[{\"name\":\"Node ID\",\"value\":\"{{.alert.NodeID}}\",\"inline\":true}{{range $key, $value := .alert.Details}},{\"name\":\"{{$key}}\",\"value\":\"{{$value}}\",\"inline\":true}{{end}}]}]}"
    }
  ]
}
```

> **Note:** During installation, the core service automatically generates an API key, stored in `/etc/serviceradar/api.env`. This API key is used for secure communication between the web UI and the core API. The key is automatically injected into API requests by the web UI's middleware, ensuring secure communication without exposing the key to clients.

### Configuration Options:

- `listen_addr`: Address and port for web dashboard API (default: ":8090")
- `grpc_addr`: Address and port for gRPC service (default: ":50052")
- `alert_threshold`: How long a service must be down before alerting (e.g., "5m" for 5 minutes)
- `known_pollers`: List of poller IDs that are allowed to connect
- `metrics`: Metrics collection settings
  - `enabled`: Whether to enable metrics collection (true/false)
  - `retention`: Number of data points to retain per metric
  - `max_nodes`: Maximum number of monitored nodes to track
- `security`: Security settings (similar to agent)
- `webhooks`: List of webhook configurations for alerts
  - `enabled`: Whether the webhook is enabled (true/false)
  - `url`: URL to send webhook notifications to
  - `cooldown`: Minimum time between repeat notifications (e.g., "15m" for 15 minutes)
  - `headers`: Custom HTTP headers to include in webhook requests
  - `template`: Custom JSON template for formatting webhook notifications

## NATS JetStream and KV Store Configuration

If you've installed the NATS Server for the KV store (see [Installation Guide](./installation.md) for setup instructions), you'll need to configure both the NATS Server and the ServiceRadar KV service.

> **Important Note:** The `serviceradar-nats` package provides configuration and systemd service files but does not install the NATS Server binary. You must first install the NATS Server binary as described in the Installation Guide before configuring the KV store.

### NATS Server Configuration

The NATS Server configuration is located at `/etc/nats/nats-server.conf`. The default configuration provided by the `serviceradar-nats` package includes mTLS and JetStream support:

```
# NATS Server Configuration for ServiceRadar KV Store

# Listen on the default NATS port (restricted to localhost for security)
listen: 127.0.0.1:4222

# Server identification
server_name: nats-serviceradar

# Enable JetStream for KV store
jetstream {
  # Directory to store JetStream data
  store_dir: /var/lib/nats/jetstream
  # Maximum storage size
  max_memory_store: 1G
  # Maximum disk storage
  max_file_store: 10G
}

# Enable mTLS for secure communication
tls {
  # Path to the server certificate
  cert_file: "/etc/serviceradar/certs/nats-server.pem"
  # Path to the server private key
  key_file: "/etc/serviceradar/certs/nats-server-key.pem"
  # Path to the root CA certificate for verifying clients
  ca_file: "/etc/serviceradar/certs/root.pem"

  # Require client certificates (enables mTLS)
  verify: true
  # Require and verify client certificates
  verify_and_map: true
}

# Logging settings
logfile: "/var/log/nats/nats.log"
debug: true
```

> **Security Note:** By default, the NATS Server is configured to listen only on the loopback interface (127.0.0.1) for security. This prevents external network access to the NATS Server. If you need to access the NATS Server from other hosts, you can modify the `listen` directive, but be sure to secure the server with proper TLS certificates and firewall rules.

After making changes to the NATS Server configuration, restart the service to apply them:

```bash
sudo systemctl restart nats
```

### ServiceRadar KV Service Configuration

The ServiceRadar KV service connects to the NATS Server and provides a gRPC interface for other ServiceRadar components to access the KV store. Edit `/etc/serviceradar/kv.json`:

```json
{
  "listen_addr": ":50057",
  "nats_url": "nats://127.0.0.1:4222",
  "security": {
    "mode": "mtls",
    "cert_dir": "/etc/serviceradar/certs",
    "server_name": "changeme",
    "role": "kv",
    "tls": {
      "cert_file": "kv.pem",
      "key_file": "kv-key.pem",
      "ca_file": "root.pem",
      "client_ca_file": "root.pem"
    }
  },
  "rbac": {
    "roles": [
      {"identity": "CN=changeme,O=ServiceRadar", "role": "reader"}
    ]
  },
  "bucket": "serviceradar-kv"
}
```

> **Note:** The `nats_url` field must match the NATS Server's listen address configuration. The format is `nats://<host>:<port>`. The default NATS Server configuration listens on 127.0.0.1 (localhost) port 4222, so the default `nats_url` value of "nats://localhost:4222" is correct. If you've modified the NATS Server configuration to listen on a different address or port, update this field accordingly.

After making changes to the KV service configuration, restart the service to apply them:

```bash
sudo systemctl restart serviceradar-kv
```

### Configuration Options:

- `listen_addr`: Address and port for the KV service gRPC API
- `nats_url`: URL for connecting to the NATS Server
- `security`: Security settings
  - `mode`: Security mode ("none" or "mtls")
  - `cert_dir`: Directory for TLS certificates
  - `server_name`: Server name for certificate verification
  - `role`: Role of this component ("server")
- `rbac`: Role-based access control settings
  - `roles`: List of role definitions
    - `identity`: Certificate subject that identifies the client
    - `role`: Role assigned to the client ("reader" or "writer")

### Enable KV Store for Agents (Future Feature)

To configure agents to use the KV store for dynamic configuration, you need to set the `CONFIG_SOURCE` environment variable in the agent's systemd service. This allows the agent to receive configuration updates from the KV store without requiring a restart.

Edit the agent's systemd service file:

```bash
sudo systemctl edit serviceradar-agent
```

Add the following lines:

```ini
[Service]
Environment="CONFIG_SOURCE=kv"
```

This tells the agent to use the KV store for configuration, using the connection details configured in the main agent configuration file.

After making this change, restart the agent service to apply the change:

```bash
sudo systemctl daemon-reload
sudo systemctl restart serviceradar-agent
```

Save the file and reload the systemd configuration:

```bash
sudo systemctl daemon-reload
```

## Optional Checker Configurations

### SNMP Checker

For monitoring network devices via SNMP, edit `/etc/serviceradar/checkers/snmp.json`:

```json
{
  "node_address": "localhost:50051",
  "listen_addr": ":50080",
  "security": {
    "server_name": "changeme",
    "mode": "none",
    "role": "checker",
    "cert_dir": "/etc/serviceradar/certs"
  },
  "timeout": "30s",
  "targets": [
    {
      "name": "router",
      "host": "192.168.1.1",
      "port": 161,
      "community": "public",
      "version": "v2c",
      "interval": "30s",
      "retries": 2,
      "oids": [
        {
          "oid": ".1.3.6.1.2.1.2.2.1.10.4",
          "name": "ifInOctets_4",
          "type": "counter",
          "scale": 1.0
        }
      ]
    }
  ]
}
```

### Dusk Node Checker

For monitoring Dusk nodes, edit `/etc/serviceradar/checkers/dusk.json`:

```json
{
  "name": "dusk",
  "type": "grpc",
  "node_address": "localhost:8080",
  "listen_addr": ":50082",
  "timeout": "5m",
  "security": {
    "mode": "none",
    "cert_dir": "/etc/serviceradar/certs",
    "role": "checker"
  }
}
```

### Network Sweep

For network scanning, edit `/etc/serviceradar/checkers/sweep/sweep.json`:

```json
{
  "networks": ["192.168.2.0/24", "192.168.3.1/32"],
  "ports": [22, 80, 443, 3306, 5432, 6379, 8080, 8443],
  "sweep_modes": ["icmp", "tcp"],
  "interval": "5m",
  "concurrency": 100,
  "timeout": "10s"
}
```

### rperf Network Checker

For network performance monitoring, edit `/etc/serviceradar/checkers/rperf.json`:

```json
{
  "listen_addr": "0.0.0.0:50081",
  "default_poll_interval": 300,
  "targets": [
    {
      "name": "Network Test",
      "address": "<server-ip>",
      "port": 5199,
      "protocol": "tcp",
      "poll_interval": 300,
      "tcp_port_pool": "5200-5210"
    }
  ]
}
```

For more information on the RPerf bandwidth checker, see the [rperf documentation](./rperf-monitoring.md).

## Web UI Configuration

The Web UI configuration is stored in `/etc/serviceradar/web.json`:

```json
{
  "port": 3000,
  "host": "0.0.0.0",
  "api_url": "http://localhost:8090"
}
```

### Configuration Options:

- `port`: The port for the Next.js application (default: 3000)
- `host`: The host address to bind to
- `api_url`: The URL for the core API service

> **Security Note:** Although the Web UI listens on port 3000 bound to all interfaces ("0.0.0.0"), this port is typically not exposed externally. Instead, Nginx proxies requests from port 80 to the Next.js service on port 3000, providing an additional security layer. You do not need to open port 3000 in your firewall for external access.

For more detailed information on the Web UI configuration, see the [Web UI Configuration](./web-ui.md) documentation.

## Next Steps

After configuring your components:

1. Restart services to apply changes:

```bash
# Basic components
sudo systemctl restart serviceradar-agent
sudo systemctl restart serviceradar-poller
sudo systemctl restart serviceradar-core

# For KV store (if installed)
sudo systemctl restart nats
sudo systemctl restart serviceradar-kv

# For Web UI (if installed)
sudo systemctl restart serviceradar-web
```

2. Verify the services are running:

```bash
# Basic components
sudo systemctl status serviceradar-agent
sudo systemctl status serviceradar-poller
sudo systemctl status serviceradar-core

# For KV store (if installed)
sudo systemctl status nats
sudo systemctl status serviceradar-kv

# For Web UI (if installed)
sudo systemctl status serviceradar-web
sudo systemctl status nginx  # Nginx is installed as a dependency of the serviceradar-web package
```

3. Visit the web dashboard by navigating to either `http://YOUR_SERVER_IP:8090` (if accessing the core service directly) or `http://YOUR_SERVER_IP` (if using the Web UI with Nginx). Remember to replace YOUR_SERVER_IP with the actual IP address or hostname of your server.

4. Review [TLS Security](./tls-security.md) to secure your components