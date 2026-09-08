---
title: Discovery Guide
---

# Discovery Guide

Discovery keeps the registry aligned with real-world infrastructure. Use Mapper for SNMP discovery and Sync for external inventory sources.

## Mapper Overview

- SNMP-first discovery engine with scheduled jobs.
- Runs inside `serviceradar-agent` and is configured via Settings → Networks → Discovery.
- Writes interface observations into `discovered_interfaces` (timeseries, 3-day retention) and topology into `mapper_topology_links` (then projects into the AGE graph).
- Supports provider API discovery alongside SNMP for selected platforms, including UniFi and MikroTik RouterOS.

## Discovery Types

- **Mapper SNMP Discovery** – populates inventory, interfaces, and topology.
- **Inventory Imports** – feed NetBox/CMDB sources through embedded Sync.
- **Sweep Jobs** – use Sync + Mapper for sweep-style coverage.

## Getting Started

1. Configure integrations in the UI.
2. Onboard a sync-capable agent.
3. Verify updates flow through DIRE into inventory.

## Supported Devices for Enriched Discovery

Mapper discovers and enriches any SNMP-capable device. For selected platforms it
also queries the vendor's native API to add identity, interface, and topology
detail beyond what SNMP alone provides.

| Source | Devices | What it adds |
| --- | --- | --- |
| SNMP / LLDP / CDP | Any SNMP-capable device — Cisco, Juniper, Arista, Aruba, and others | Baseline inventory, interfaces, and L2/L3 topology |
| MikroTik RouterOS API | MikroTik routers and switches | Device identity, full interface inventory, bridge/VLAN context, neighbor evidence — see below |
| Ubiquiti UniFi API | UniFi controllers and managed devices | Site and device inventory with port-level topology |
| Proxmox VE API | Proxmox VE hypervisors | Guest and host inventory — see [Proxmox VE](./proxmox.md) |

SNMP, LLDP, and CDP remain the universal baseline and are authoritative wherever
they provide stronger interface attribution than vendor-API data.

Need enriched API discovery for a platform that is not listed? Open a request on
the [ServiceRadar repository](https://github.com/carverauto/serviceradar/issues)
so it can be prioritized.

## MikroTik RouterOS API Discovery

ServiceRadar can query MikroTik RouterOS directly from the edge agent by using the RouterOS REST API over HTTP(S). The current implementation is read-only and is intended to improve device identity, interface coverage, and topology evidence without replacing SNMP where SNMP remains stronger.

### Setup Requirements

- RouterOS must expose the REST API at `http(s)://<router>/rest`.
- In ServiceRadar, RouterOS controller URLs are normalized to the `/rest` base path automatically, so either `https://192.168.88.1` or `https://192.168.88.1/rest` is accepted.
- ServiceRadar uses HTTP Basic authentication from the agent to the router.
- Prefer `https` with `www-ssl` enabled on RouterOS. Use `insecure_skip_verify` only for lab or bootstrap scenarios.
- Restrict management-plane reachability so only the agent network can reach the RouterOS API.

### Phase 1 Coverage

- Device identity: hostname, RouterOS version, vendor, model/board, serial number, architecture
- Interface inventory: physical, bridge, VLAN, bonding, loopback, and tunnel-style interfaces exposed by RouterOS
- L2/L3 context: bridge-port membership, bridge VLAN membership, and interface IP addresses
- Neighbor evidence: best-effort RouterOS neighbor data when available

### Scope And Limits

- The integration is read-only. ServiceRadar does not push config, execute commands, or manage RouterOS state.
- REST resource coverage varies by RouterOS version. Unsupported endpoints degrade to partial discovery rather than failing the full mapper run.
- SNMP, LLDP, and CDP remain authoritative when they provide stronger interface attribution than RouterOS neighbor data.

### Validating RouterOS API Discovery

After enabling RouterOS API discovery against a router, confirm the data lands in
the registry. Look in the device's detail view, or query the platform tables for
the device, and check the following:

1. `ocsf_devices.os` includes `RouterOS` name/version data.
2. `ocsf_devices.hw_info` includes serial and architecture when the router exposes them.
3. `discovered_interfaces.metadata->>'source'` shows `mikrotik-api` on RouterOS-derived interfaces.
4. `mapper_topology_links` contains `mikrotik-api-neighbor` evidence if the router exposes neighbor data.
