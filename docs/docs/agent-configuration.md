---
title: Agent Configuration
---

# Agent Configuration

The ServiceRadar **agent** runs at the edge of a monitored network. It executes
checks (ping, port, HTTP, traceroute, and more), collects results, and pushes
them to an **agent-gateway** over a secure connection.

## Configuration is managed centrally

You do not hand-edit agent configuration on the agent host. Agent configuration
is managed by the ServiceRadar backend and **pushed down from the agent-gateway
to the agent**. Operators configure agents — and the checks they run — through
the **Web UI**; the agent receives its configuration over its connection to the
gateway and applies it automatically.

Editing configuration on the agent host directly is not the supported workflow:
the next configuration push from the gateway overwrites local changes.

- To onboard an agent, see [Edge Agent Onboarding](./edge-agent-onboarding.md).
- To configure what an agent does, use the Web UI — see the check types below
  and [Network Sweeps](./network-sweeps.md), [SNMP](./snmp.md),
  [Sysmon Profiles](./sysmon-profiles.md),
  [Visibility Profiles](./visibility-profiles.md), and
  [Discovery](./discovery.md).

## The bootstrap file

The agent has one small local file — its **bootstrap configuration**,
`/etc/serviceradar/agent.json` by default. It is generated for you during
enrollment (`srctl enroll`) and only tells the agent how to start up
and reach the gateway. Once the agent connects, everything else is delivered by
the gateway.

| Field | Purpose |
| --- | --- |
| `gateway_addr` | Address (`host:port`) of the agent-gateway. The agent will not start without it. |
| `agent_id` / `agent_name` | This agent's identity. |
| `gateway_security` | TLS/mTLS settings for the gateway connection — mode, cert directory, server name, and cert/key/CA files. |
| `host_ip` / `partition` | Used for device correlation. |
| `logging` | Log level and output, plus an optional `otel` block for OpenTelemetry export. See [OpenTelemetry](./otel.md). |

The enrollment flow writes this file for you. You should not need to edit it by
hand; operational configuration (which checks to run, sweep/SNMP/sysmon
profiles, discovery jobs, plugins) is delivered by the gateway, not stored here.

:::note Deprecated field
`remote_access_known_hosts_file` is **deprecated**. It is still accepted for
compatibility with older rendered ConfigMaps but no longer has any effect.
Remote-access host keys are managed in the Web UI under
**Settings → Networks → Host Keys**.
:::

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

All checks are created and configured from the **Web UI**. The agent simply
executes whatever check set the gateway sends it.

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
