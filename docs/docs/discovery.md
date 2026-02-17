---
title: Discovery Guide
---

# Discovery Guide

Discovery keeps the registry aligned with real-world infrastructure. Use Mapper for SNMP discovery and Sync for external inventory sources.

## Mapper Overview

- SNMP-first discovery engine with scheduled jobs.
- Runs inside `serviceradar-agent` and is configured via Settings → Networks → Discovery.
- Writes interface observations into `discovered_interfaces` (timeseries, 3-day retention) and topology into `mapper_topology_links` (then projects into the AGE graph).

## Discovery Types

- **Mapper SNMP Discovery** – populates inventory, interfaces, and topology.
- **Inventory Imports** – feed NetBox/CMDB sources through embedded Sync.
- **Sweep Jobs** – use Sync + Mapper for sweep-style coverage.

## Getting Started

1. Configure integrations in the UI.
2. Onboard a sync-capable agent.
3. Verify updates flow through DIRE into inventory.

## Topology Cleanup/Rebuild

For polluted topology evidence or unstable adjacency after parser/pipeline fixes, use the
[Topology Reset and Rebuild Runbook](./topology-reset-rebuild.md).
