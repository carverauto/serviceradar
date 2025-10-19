---
title: Discovery Guide
---

# Discovery Guide

ServiceRadar discovery jobs keep the registry aligned with real-world infrastructure by walking networks, inventory services, and cataloging dependencies. Use discovery to seed the registry before enabling continuous polling.

## Mapper Service Overview

The `serviceradar-mapper` service is the SNMP-first discovery engine that complements sweep jobs and external imports. It exposes gRPC endpoints (`discovery.DiscoveryService` and `monitoring.AgentService`) for on-demand scans, and it can run scheduled discovery without any external trigger. Mapper loads its settings from `/etc/serviceradar/mapper.json` (mounted from `docker/compose/mapper.docker.json` in Docker or rendered via the Helm chart) and keeps its own worker pool so discovery does not compete with poller workloads.

### Publishing Flow

- Newly discovered devices are normalized through the device registry and land in the Proton `device_updates` stream with `discovery_source = 'mapper'`. That keeps reconciliation logic consistent with sweep, Armis, and Sync imports.
- Interface inventories are written to the `discovered_interfaces` table, and topology links flow into `topology_discovery_events`. Use SRQL queries such as `in:interfaces time:last_1h limit:20` to spot-check mapper output.
- Mapper enriches each record with the `agent_id`, `poller_id`, and `partition` defined under `stream_config`, so downstream alerts and dashboards can segment results by environment.

### Configuring `mapper.json`

Mapper reads a single JSON document; the most important sections are:

- **`workers`, `max_active_jobs`, `timeout`, `retries`** – govern concurrency and job lifecycle. Keep `workers` below the number of SNMP sessions your network can tolerate.
- **`default_credentials` and `credentials[]`** – define global SNMP v2c/v3 credentials plus CIDR-specific overrides. CIDR matches are evaluated in order; list the most specific ranges first.
- **`oids`** – per-discovery-type OID sets. `basic`, `interfaces`, and `topology` ship with sensible defaults, but you can add vendor-specific OIDs as needed.
- **`stream_config`** – names the Proton streams (`device_stream`, `interface_stream`, `topology_stream`) and tags emitted events with `agent_id`, `poller_id`, and optional `partition`. Defaults point to `sweep_results`, `discovered_interfaces`, and `topology_discovery_events`.
- **`scheduled_jobs[]`** – cron-like definitions that launch discovery on an interval. Each job supplies `seeds` (IPs, hosts, or subnets), the discovery `type` (`full`, `basic`, `interfaces`, or `topology`), credentials override, concurrency, timeout, and retry budget.
- **`unifi_apis[]`** – optional UniFi controller integrations. Provide `base_url`, `api_key`, and set `insecure_skip_verify` only when testing lab controllers.
- **`security` / `logging`** – mTLS endpoints and OTLP exporter settings so mapper aligns with the wider ServiceRadar transport policies.

For Docker deployments, edit `docker/compose/mapper.docker.json` and restart the `serviceradar-mapper` container. For Helm/Kubernetes, override `mapper.json` via a values file as described in the [Helm configuration guide](./helm-configuration.md#mapper-service-settings).

## Discovery Types

- **Sweep Jobs** – Lightweight ICMP/TCP probes that identify live hosts. Configure CIDR blocks and schedules in the registry; see the [Sync guide](./sync.md) for API examples.
- **Mapper SNMP Discovery** – Mapper-driven SNMP walks that populate inventory, interface, and topology data. Tune jobs in `/etc/serviceradar/mapper.json` and monitor results with SRQL on `device_updates` and `discovered_interfaces`.
- **Service Fingerprints** – Port- and banner-based detectors that classify applications. Maintain fingerprints in KV so updates roll out without redeploying pollers.
- **Inventory Imports** – External sources such as NetBox or CMDB dumps. Feed them through the Sync service and let reconciliation create or merge registry entries.

## Creating Jobs

1. Define scopes (CIDRs, tags, tenants) and store them in KV under `discovery/jobs/<name>.json`.
2. Assign jobs to pollers by label; larger scopes benefit from multiple pollers sharing the workload.
3. Schedule frequency based on change rate—daily for core data centers, weekly for branch offices.

## Reviewing Results

- Discovery events land in Proton (`discovery.events` table). Run SRQL queries like `SELECT * FROM discovery.events ORDER BY observed_at DESC LIMIT 20;`.
- New devices appear in the registry with the `discovered=true` flag until validated via SNMP or NetFlow. Use the [Service Port Map](./service-port-map.md) to triage.
- Sync workflows can auto-close stale discoveries; adjust thresholds in the [Sync configuration](./sync.md).

## Best Practices

- Whitelist management networks and respect change windows—discovery traffic can look suspicious to IDS tools.
- Tag discoveries with owners or teams so follow-up tasks route cleanly.
- Combine discovery with OTEL resource detection to build full-stack visibility from day one.
