---
title: SNMP Ingest Guide
---

# SNMP Ingest Guide

Simple Network Management Protocol (SNMP) polling remains the fastest way to populate ServiceRadar with device inventory and health metrics. Use this guide alongside the detailed [Device Configuration Reference](./device-configuration.md#snmp-configuration) to standardize credentials, access, and polling strategy.

## Prepare Pollers

1. Ensure each poller can reach monitored devices on UDP 161 (and UDP 162 if you plan to receive traps).
2. Store SNMP communities or v3 credentials in the KV store so pollers can refresh secrets without redeploys. Follow the [KV configuration](./kv-configuration.md) examples for encrypted values.
3. Map device targets to the correct SNMP profile inside the registry. The [Sync service guide](./sync.md) explains how to seed profiles programmatically.

## Define Credentials

- **SNMPv2c** – use unique read-only community strings per device class; avoid `public` or `private`.
- **SNMPv3** – prefer `authPriv` with SHA-256 and AES-256 where devices allow. Record usernames, auth passwords, and privacy keys in KV.
- Rotate secrets quarterly and update the registry via Sync to prevent stale poller configs.

## Build Polling Plans

- Start with 60-second intervals for critical devices and 5-minute intervals for access-layer gear.
- Group OIDs into logical bundles (interfaces, CPU/memory, trap status) to minimize round trips.
- Track historical polls in Proton for long-term trend analysis; see the [Proton overview](./proton.md) for retention defaults.

## Enable Traps

Traps complement polling by pushing urgent events:

1. Configure devices to send traps to the ServiceRadar gateway address on UDP 162.
2. Expose the trap listener service in Kubernetes with a `LoadBalancer` or NodePort, or map it locally in Docker Compose.
3. Confirm delivery with `tcpdump` or `kubectl logs` on the trap receiver pod.

## Validate Collection

- Use `serviceradarctl poller check` to run ad-hoc queries against new devices.
- Inspect SRQL queries such as `SELECT * FROM snmp.interfaces WHERE device = '<hostname>' LIMIT 10;` to verify ingestion.
- Set up baseline alerts once metrics stabilize—see the [Troubleshooting Guide](./troubleshooting-guide.md#snmp) for common failure modes.
