---
title: NetFlow Ingest Guide
---

# NetFlow Ingest Guide

ServiceRadar ingests flow telemetry to expose traffic matrices, top talkers, and application reachability trends. The NetFlow collector ships with the gateway image and relays enriched flow records into the CNPG telemetry database.

## Collector Layout

- **Listener**: The gateway exposes UDP 2055 for NetFlow v5/v9/IPFIX. When running in Kubernetes, bind the service via `serviceradar-netflow`.
- **Buffering**: Flow packets land in a bounded queue; tune `NETFLOW_QUEUE_DEPTH` in the gateway deployment for high-volume environments.
- **Forwarder**: Parsed flows are batched into CNPG using the `netflow.flows` Timescale table schema.

## Device Configuration

1. Enable NetFlow export on routers, aggregation switches, or firewalls. Point the destination to the gateway address.
2. Set active and inactive timeouts (commonly 60s/15s) to balance detail with bandwidth.
3. Export IPFIX templates when available; ServiceRadar infers fields dynamically and stores custom enterprise elements.

## Registry and Metadata

- Use the embedded sync runtime (agent) to register flow exporters with site, tenant, and device tags.
- Populate interface maps in the registry so flows can be joined with SNMP interface stats.
- Capture application dictionaries (port → service mapping) in KV to improve SRQL readability.

## Verification

- Query CNPG with `SELECT * FROM netflow.flows ORDER BY start_time DESC LIMIT 20;`.
- Visualize top talkers in the Web UI by enabling the `NetFlow Traffic` dashboard (see the [Web UI configuration](./web-ui.md)).
- Check the [Troubleshooting Guide](./troubleshooting-guide.md#netflow) for packet loss, template mismatch, and exporter clock drift remedies.
