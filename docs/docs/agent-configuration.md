---
title: Agent Configuration
---

# Agent Configuration

The ServiceRadar **agent** runs at the edge of a monitored network. It executes
checks (ping, port, HTTP, traceroute, and more), collects results, and pushes
them to an **agent-gateway** over a secure connection. This page describes the
agent's configuration file and the checks it can run.

For getting an agent installed and enrolled, see
[Edge Agent Onboarding](./edge-agent-onboarding.md).

## The configuration file

The agent reads a JSON configuration file. By default it loads
`/etc/serviceradar/agent.json`; a different path can be passed with the
`--config` flag.

A config file is **required**. If the file is missing, the agent exits with an
error — unless the environment variable `SR_ALLOW_EMBEDDED_DEFAULT_CONFIG=true`
is set, in which case it falls back to a built-in default config (intended for
quick local testing only). The file must be valid JSON with no trailing data.

### Key fields

| Field | Required | Description |
| --- | --- | --- |
| `gateway_addr` | **Yes** | Address (`host:port`) of the agent-gateway the agent pushes status to. The agent will not start without it. |
| `agent_id` | Recommended | Unique identifier for this agent. |
| `agent_name` | Optional | Explicit name used for KV namespacing. |
| `component_type` | Optional | Component type — `agent`, `gateway`, or `checker`. |
| `host_ip` | Optional | Host IP address, used for device correlation. |
| `partition` | Optional | Partition name, used for device correlation. |
| `gateway_security` | Recommended | Security config for the gateway connection (TLS/mTLS — mode, cert directory, server name, role, cert/key/CA files). |
| `push_interval` | Optional | How often the push loop runs (default `30s`; bounded between `1s` and `1h`). |
| `status_debounce_interval` | Optional | Minimum interval between pushes when status has not changed. |
| `status_heartbeat_interval` | Optional | Maximum interval between status pushes — a heartbeat even when nothing changed. |
| `sync_runtime_enabled` | Optional | Enables the embedded integration sync runtime. |
| `remote_access_rdp_enabled` | Optional | Gates the per-session RDP helper. The agent advertises RDP remote access only when this is enabled **and** the RDP helper binary is locally executable. |
| `remote_access_rdp_adapter_path` | Optional | Path to the RDP adapter/helper binary. |
| `checkers_dir` | Optional | Directory containing checker plugin definitions (default `/etc/serviceradar/checkers`). |
| `kv_address` | Optional | Address of a KV store, if the agent reads config from KV. |
| `kv_security` | Optional | Separate security config for the KV connection. |
| `logging` | Optional | Logging configuration — `level`, `output`, and a nested `otel` block for OpenTelemetry export. |

The `logging.otel` block enables OpenTelemetry export of agent logs/telemetry
(endpoint, service name, batch timeout, TLS). See [OpenTelemetry](./otel.md) for
the wider observability pipeline.

:::note Deprecated field
`remote_access_known_hosts_file` is **deprecated**. It is still accepted for
compatibility with older rendered ConfigMaps but no longer has any effect.
Remote-access host keys are now managed in the Web UI under
**Settings → Networks → Host Keys**.
:::

### Example

```json
{
  "agent_id": "edge-agent-01",
  "agent_name": "branch-office",
  "host_ip": "10.20.0.5",
  "partition": "branch-office",
  "gateway_addr": "agent-gateway:50052",
  "push_interval": "30s",
  "status_debounce_interval": "30s",
  "status_heartbeat_interval": "5m",
  "sync_runtime_enabled": true,
  "checkers_dir": "/etc/serviceradar/checkers",
  "gateway_security": {
    "mode": "mtls",
    "cert_dir": "/etc/serviceradar/certs",
    "server_name": "agent-gateway",
    "role": "client",
    "tls": {
      "cert_file": "agent.pem",
      "key_file": "agent-key.pem",
      "ca_file": "root.pem"
    }
  },
  "logging": {
    "level": "info",
    "output": "stdout"
  }
}
```

## Agent check types

Once enrolled, the agent receives its check definitions from the gateway. Each
check has a type that tells the agent what to do:

| Type | What it does |
| --- | --- |
| `icmp` | Sends ICMP echo (ping) probes to a target and reports availability, response time, and packet loss. |
| `tcp` | Opens a TCP connection to a host and port to confirm the service is listening. |
| `http` | Issues an HTTP/HTTPS request to a target URL (with a configurable method and path) and checks the response. |
| `grpc` | Performs a gRPC health probe against a target host and port. |
| `process` | Verifies that a named process is running on the agent host. |
| `sweep` | Runs a network sweep across one or more networks/ports to discover and check hosts. See [Network Sweeps](./network-sweeps.md). |
| `mtr` | Runs a scheduled traceroute (My Traceroute) to a target — see below. |

Most checks are created and configured from the **Web UI**, not in the agent
config file. The agent simply executes whatever check set the gateway sends it.

### MTR (My Traceroute) checks

An `mtr` check runs a scheduled traceroute to a target on a recurring interval
and reports the per-hop path, latency, and packet loss. This is useful for
detecting where in the network a connectivity or latency problem occurs.

Each MTR check supports these settings:

| Setting | Description | Default |
| --- | --- | --- |
| `max_hops` | Maximum number of hops to probe. | 30 (cap: 64) |
| `probes_per_hop` | Number of probes sent per hop. | 3 (cap: 20) |
| `protocol` | Probe protocol — `icmp`, `udp`, or `tcp`. | `icmp` |
| `probe_interval_ms` | Delay between probes, in milliseconds. | provider default (cap: 10000) |
| `packet_size` | Probe packet size, in bytes. | provider default (cap: 1500) |
| `dns_resolve` | Whether to resolve hop IPs to hostnames. | `true` |

To protect the agent and the network, all remotely supplied MTR values are
**clamped to safe upper bounds** (shown above). Any value below 1 is raised to
1, and any value above the cap is reduced to the cap.

MTR checks can also be run interactively from the Web UI under
**Diagnostics → MTR**, and recurring MTR profiles are managed under
**Settings → Networks → MTR**.
