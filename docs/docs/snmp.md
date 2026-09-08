---
title: SNMP Ingest Guide
---

# SNMP Ingest Guide

Simple Network Management Protocol (SNMP) polling remains the fastest way to populate ServiceRadar with device inventory and health metrics. Use this guide alongside the detailed [Device Configuration Reference](./device-configuration.md#snmp-configuration) to standardize credentials, access, and polling strategy.

SNMP polling is an **embedded service inside the ServiceRadar agent** — not a separate gateway component. Each agent runs its own SNMP poller and reaches monitored devices directly. Deploy agents close to the network gear you want to poll. See [Embedded Agent SNMP](#embedded-agent-snmp) below for configuration details.

## Prepare Agents

1. Ensure each agent can reach its monitored devices on UDP 161 (and that devices can reach the trap collector on UDP 162 if you plan to receive traps).
2. Store SNMP communities or v3 credentials in SNMP Profiles so agents can refresh secrets without redeploys.
3. Map device targets to the correct SNMP profile. The [sync runtime guide](./sync.md) explains how to seed targets programmatically.

## Define Credentials

- **SNMPv2c** – use unique read-only community strings per device class; avoid `public` or `private`.
- **SNMPv3** – prefer `authPriv` with SHA-256 and AES-256 where devices allow. Record usernames, auth passwords, and privacy keys in profiles.
- Rotate secrets quarterly and update SNMP Profiles via the embedded sync runtime to prevent stale agent configs.

## Build Polling Plans

- Start with 60-second intervals for critical devices and 5-minute intervals for access-layer gear.
- Group OIDs into logical bundles (interfaces, CPU/memory, trap status) to minimize round trips.
- Track historical polls in the CNPG/Timescale hypertables (`timeseries_metrics`, `cpu_metrics`, `interface_metrics`) for long-term trend analysis; see the [CNPG monitoring guide](./cnpg-monitoring.md) for queries you can reuse inside Grafana.

## Enable Traps

Traps complement polling by pushing urgent events:

1. Configure devices to send traps to the ServiceRadar trap collector address on UDP 162.
2. Make the trap listener reachable only from trusted device networks, for example through a private `LoadBalancer`, private `NodePort`, VPN-routed service, or Docker Compose port mapping. Keep the actual collector address in private operations material; see [Kubernetes External Ingestion](./kubernetes-ingestion.md).
3. Confirm delivery with `tcpdump` or `kubectl logs` on the trap receiver pod.

`serviceradar-trapd` is stateless; see `helm/serviceradar/files/serviceradar-config.yaml` or `build/packaging/trapd/config/trapd.json` for base settings you can override through file edits or a pinned overlay.

**trapd security:** trapd's gRPC interface supports a `SecurityMode` of `mtls` (the default), `spiffe`, or `none`. When `grpc_listen_addr` is set, `none` is rejected — the gRPC endpoint must use `mtls` or `spiffe`. The default gRPC health/listener address is `0.0.0.0:50043`. For SPIFFE mode, a `trust_domain` is required. Keep the trap UDP port (162) and the gRPC port restricted to trusted networks.

## Trap Processing Pipeline

1. `serviceradar-trapd` publishes each decoded trap as JSON to the NATS JetStream
   stream `events` on the `logs.snmp` subject.
2. `serviceradar_core` consumes the same raw subject, evaluates the bundled Zen
   rules through a Rustler NIF, and persists the normalized trap log into CNPG.
3. Keeping raw subjects in one stream lets you replay traps after adjusting code
   or bundled rules.

## Default Trap Rules

- `snmp_severity` normalizes the severity field to a known value if the trap
  does not supply one. Review the bundled JSON under
  `elixir/serviceradar_core/priv/zen/rules/snmp_severity.json`.
- `passthrough` is available for cases where you only need the `.processed` suffix without transformations; it copies the input event unchanged.

These and the syslog-focused rules share the same GoRules/zen runtime. Use the Rule Builder UI to manage them; see the [Rule Builder](./rule-builder.md) guide.

## Managing Rules

- Use **Settings -> Events** to manage rule templates for SNMP traps.
- In normal operation, rule distribution is handled by the control plane. You
  should not need to write NATS keys by hand.

## Validate Collection

- Use `serviceradarctl gateway check` to run ad-hoc queries against new devices.
- Inspect SRQL queries such as `SELECT * FROM snmp.interfaces WHERE device = '<hostname>' LIMIT 10;` to verify ingestion.
- Set up baseline alerts once metrics stabilize—see the [Troubleshooting Guide](./troubleshooting-guide.md#snmp) for common failure modes.

---

## Embedded Agent SNMP

ServiceRadar agents can poll SNMP targets directly without a separate gateway component. This embedded SNMP capability allows for distributed monitoring where agents deployed close to network devices can collect metrics locally.

### Configuration

The embedded SNMP service is configured through SNMP Profiles in the ServiceRadar UI. Navigate to **Settings → SNMP Profiles** to manage your configuration.

#### SNMP Profiles

Profiles define the monitoring parameters and can be targeted to specific devices using SRQL queries:

| Field | Description |
|-------|-------------|
| Name | Display name for the profile |
| Target Query | SRQL query to match devices (e.g., `in:devices hostname:router-*`) |
| Priority | Higher priority profiles are evaluated first when multiple profiles match |
| Enabled | Enable/disable the profile |
| Poll Interval | How often to poll targets (seconds) |
| Timeout | SNMP request timeout (seconds) |
| Retries | Number of retry attempts on failure |

#### SNMP Targets

Each profile contains one or more SNMP targets:

| Field | Description |
|-------|-------------|
| Name | Display name for the target |
| Host | IP address or hostname of the SNMP device |
| Port | SNMP port (default: 161) |
| Version | SNMP version: v1, v2c, or v3 |

**SNMPv2c Configuration:**
- Community: The SNMP community string

**SNMPv3 Configuration:**
- Username: SNMPv3 username
- Security Level: noAuthNoPriv, authNoPriv, or authPriv
- Auth Protocol: MD5 or SHA
- Auth Password: Authentication password
- Priv Protocol: DES or AES
- Priv Password: Privacy password

#### OID Configuration

Configure which OIDs to poll for each target. You can use the built-in OID templates or define custom OIDs:

| Field | Description |
|-------|-------------|
| OID | The SNMP OID string (e.g., `.1.3.6.1.2.1.1.3.0`) |
| Name | Human-readable name for the metric |
| Data Type | gauge, counter, string, integer, or timeticks |
| Scale | Multiplier to apply to the value |
| Delta | Calculate rate of change (for counters) |

### OID Templates

ServiceRadar includes built-in OID templates for common device types:

**Standard (MIB-II):**
- Interface Statistics: ifInOctets, ifOutOctets, ifOperStatus, ifSpeed
- System Info: sysDescr, sysUpTime, sysName, sysLocation
- IP Statistics: ipInReceives, ipOutRequests, ipInDiscards

**Cisco:**
- CPU/Memory: cpmCPUTotal5sec, cpmCPUTotal1min, ciscoMemoryPoolUsed
- Environment: ciscoEnvMonTemperatureValue, ciscoEnvMonFanState
- BGP: cbgpPeerState, cbgpPeerPrefixAccepted

**Juniper:**
- CPU/Memory: jnxOperatingCPU, jnxOperatingBuffer, jnxOperatingMemory
- Environment: jnxOperatingTemp, jnxOperatingState

**Arista:**
- Environment: aristaEnvMonTempValue, aristaEnvMonFanState

Create custom templates from the **Custom** tab in the OID Template browser.

### Local Configuration Override

Agents can use a local configuration file that overrides control plane settings:

```json
// /etc/serviceradar/snmp.json
{
  "enabled": true,
  "targets": [
    {
      "name": "local-router",
      "host": "192.168.1.1",
      "port": 161,
      "version": "v2c",
      "community": "private",
      "poll_interval_seconds": 30,
      "timeout_seconds": 5,
      "retries": 2,
      "oids": [
        {
          "oid": ".1.3.6.1.2.1.1.3.0",
          "name": "sysUpTime",
          "data_type": "timeticks"
        }
      ]
    }
  ]
}
```

Local configuration takes precedence over remote profiles, allowing site-specific overrides.

### SRQL-Based Targeting

Use SRQL queries to automatically apply SNMP profiles to matching devices:

```
# Match all routers
in:devices hostname:router-*

# Match devices with specific tags
in:devices tags.role:network

# Match devices by type
in:devices type:Router

# Combine conditions
in:devices hostname:%core% type:Switch
```

The profile with the highest priority that matches a device is used. If no targeting profile matches, the default profile (if one exists) is applied.

### Monitoring Agent SNMP Status

The agent runs in push mode: it does not expose an HTTP status endpoint. SNMP service status is reported over the agent's gRPC interface and surfaced in the ServiceRadar UI and core API. For direct inspection, check the agent logs:

```bash
# View agent logs for SNMP activity
kubectl logs -f deploy/serviceradar-agent | grep -i snmp
```

Reported SNMP status includes:
- Whether SNMP is enabled
- Number of active targets
- Config source (remote, local file, or cached)
- Config hash for change detection
