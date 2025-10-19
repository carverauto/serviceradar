---
title: Discovery Guide
---

# Discovery Guide

ServiceRadar discovery jobs keep the registry aligned with real-world infrastructure by walking networks, inventory services, and cataloging dependencies. Use discovery to seed the registry before enabling continuous polling.

## Discovery Types

- **Sweep Jobs** – Lightweight ICMP/TCP probes that identify live hosts. Configure CIDR blocks and schedules in the registry; see the [Sync guide](./sync.md) for API examples.
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
