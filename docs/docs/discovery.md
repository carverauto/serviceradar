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

### Demo Validation

Use the live CHR target in `demo` as the validation baseline:

- Device UID: `sr:36e0e348-6da6-4474-bb3c-f7af1eb4d5b8`
- Expected management IP: `192.168.6.167`

Cluster-side validation commands:

```bash
kubectl exec -n demo cnpg-10 -- bash -lc \
  "PGPASSWORD='<serviceradar-db-password>' psql -h cnpg-rw -U serviceradar -d serviceradar \
  -c \"SELECT uid, hostname, ip, vendor_name, model, os, hw_info, discovery_sources
      FROM platform.ocsf_devices
      WHERE uid = 'sr:36e0e348-6da6-4474-bb3c-f7af1eb4d5b8';\""
```

```bash
kubectl exec -n demo cnpg-10 -- bash -lc \
  "PGPASSWORD='<serviceradar-db-password>' psql -h cnpg-rw -U serviceradar -d serviceradar \
  -c \"SELECT device_id, device_ip, if_name, metadata->>'source' AS source
      FROM platform.discovered_interfaces
      WHERE device_id = 'sr:36e0e348-6da6-4474-bb3c-f7af1eb4d5b8'
      ORDER BY timestamp DESC
      LIMIT 20;\""
```

```bash
kubectl exec -n demo cnpg-10 -- bash -lc \
  "PGPASSWORD='<serviceradar-db-password>' psql -h cnpg-rw -U serviceradar -d serviceradar \
  -c \"SELECT timestamp, protocol, metadata->>'source' AS source,
             local_if_name, neighbor_system_name, neighbor_mgmt_addr
      FROM platform.mapper_topology_links
      WHERE local_device_id = 'sr:36e0e348-6da6-4474-bb3c-f7af1eb4d5b8'
      ORDER BY timestamp DESC
      LIMIT 20;\""
```

Post-deploy success criteria for RouterOS API validation:

1. `ocsf_devices.os` includes `RouterOS` name/version data.
2. `ocsf_devices.hw_info` includes serial and architecture when the router exposes them.
3. `discovered_interfaces.metadata->>'source'` shows `mikrotik-api` on RouterOS-derived interfaces.
4. `mapper_topology_links` contains `mikrotik-api-neighbor` evidence if the CHR exposes neighbor data.

## Topology Cleanup/Rebuild

For polluted topology evidence or unstable adjacency after parser/pipeline fixes, use the
[Topology Reset and Rebuild Runbook](./topology-reset-rebuild.md).
That runbook also defines rollout/rollback flags for v2 contract ingestion and AGE-authoritative
render cutover.
