---
title: Discovery Guide
---

# Discovery Guide

ServiceRadar discovery jobs keep the registry aligned with real-world infrastructure by walking networks, inventory services, and cataloging dependencies. Use discovery to seed the registry before enabling continuous polling.

## Mapper Service Overview

The `serviceradar-mapper` service is the SNMP-first discovery engine that complements sweep jobs and external imports. It exposes gRPC endpoints (`discovery.DiscoveryService` and `monitoring.AgentService`) for on-demand scans, and it can run scheduled discovery without any external trigger. Mapper loads its settings from `/etc/serviceradar/mapper.json` (mounted from `docker/compose/mapper.docker.json` in Docker or rendered via the Helm chart) and keeps its own worker pool so discovery does not compete with poller workloads.

### Publishing Flow

- Newly discovered devices are normalized through the device registry and land in the CNPG `device_updates` stream with `discovery_source = 'mapper'`. That keeps reconciliation logic consistent with sweep, Armis, and Sync imports.
- Interface inventories are written to the `discovered_interfaces` table, and topology links flow into `topology_discovery_events`. Use SRQL queries such as `in:interfaces time:last_1h limit:20` to spot-check mapper output.
- Mapper enriches each record with the `agent_id`, `poller_id`, and `partition` defined under `stream_config`, so downstream alerts and dashboards can segment results by environment.

### Configuring `mapper.json`

Mapper reads a single JSON document; the most important sections are:

- **`workers`, `max_active_jobs`, `timeout`, `retries`** - govern concurrency and job lifecycle. Keep `workers` below the number of SNMP sessions your network can tolerate.
- **`default_credentials` and `credentials[]`** - define global SNMP v2c/v3 credentials plus CIDR-specific overrides. CIDR matches are evaluated in order; list the most specific ranges first.
- **`oids`** - per-discovery-type OID sets. `basic`, `interfaces`, and `topology` ship with sensible defaults, but you can add vendor-specific OIDs as needed.
- **`stream_config`** - names the CNPG streams (`device_stream`, `interface_stream`, `topology_stream`) and tags emitted events with `agent_id`, `poller_id`, and optional `partition`. Defaults point to `sweep_results`, `discovered_interfaces`, and `topology_discovery_events`.
- **`scheduled_jobs[]`** - cron-like definitions that launch discovery on an interval. Each job supplies `seeds` (IPs, hosts, or subnets), the discovery `type` (`full`, `basic`, `interfaces`, or `topology`), credentials override, concurrency, timeout, and retry budget.
- **`unifi_apis[]`** - optional UniFi controller integrations. Provide `base_url`, `api_key`, and set `insecure_skip_verify` only when testing lab controllers.
- **`security` / `logging`** - mTLS endpoints and OTLP exporter settings so mapper aligns with the wider ServiceRadar transport policies.

For Docker deployments, edit `docker/compose/mapper.docker.json` and restart the `serviceradar-mapper` container. For Helm/Kubernetes, override `mapper.json` via a values file as described in the [Helm configuration guide](./helm-configuration.md#mapper-service-settings).

## Discovery Types

- **Mapper SNMP Discovery** - Mapper-driven SNMP walks that populate inventory, interface, and topology data. Tune jobs in `/etc/serviceradar/mapper.json` and monitor results with SRQL on `device_updates` and `discovered_interfaces`.
- **Inventory Imports** - External sources such as NetBox or CMDB exports. Feed them through the Sync service and let DIRE reconcile devices into the canonical inventory.
- **Sweep Jobs (Legacy)** - Pull-based sweeps are deprecated in the push-first architecture. New discovery flows should use Sync and Mapper outputs instead.

## Creating Jobs

1. Configure integrations in the UI under **Integrations -> New Source** for each tenant.
2. Onboard a sync service (platform or edge) and ensure it can reach agent-gateway over mTLS.
3. Core delivers source configs via `GetConfig`, and the sync service streams device updates back through agent-gateway.

## Reviewing Results

- Discovery events and device updates flow through DIRE before reaching the inventory tables. Use SRQL to inspect recent device updates or inventory changes.
- Sync-originated updates carry tenant context derived from mTLS; verify correct tenancy by querying per-tenant inventory views.
- Mapper outputs continue to populate interface and topology tables (`discovered_interfaces`, `topology_discovery_events`).

## Best Practices

- Whitelist management networks and respect change windows - discovery traffic can look suspicious to IDS tools.
- Keep integration sources scoped per tenant and validate mTLS identity before onboarding edge sync services.
- Combine Sync, Mapper, and OTEL signals to build full-stack visibility from day one.
