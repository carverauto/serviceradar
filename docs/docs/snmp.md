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

`serviceradar-trapd` is stateless; see `helm/serviceradar/files/serviceradar-config.yaml` or `packaging/trapd/config/trapd.json` for base settings you can override through the KV overlay.

## Trap Processing Pipeline

1. `serviceradar-trapd` publishes each decoded trap as JSON to the NATS JetStream stream `events`. The default subject is `snmp.traps`; if you prefer the zen defaults, set it to `events.snmp` so the decision group matches without additional rewrites.
2. `serviceradar-zen` attaches to the same stream using the `zen-consumer` durable. The SNMP decision group listens for `events.snmp`, mutates the payload, and republishes it with the `.processed` suffix (`events.snmp.processed`).
3. `serviceradar-db-event-writer` drains the `.processed` subjects and bulk loads the results into Proton. Keeping raw and processed subjects in one stream lets you replay traps after adjusting rules.

## Default Trap Rules

- `snmp_severity` normalizes the severity field to a known value if the trap does not supply one. Review the JSON under `packaging/zen/rules/snmp_severity.json`.
- `passthrough` is available for cases where you only need the `.processed` suffix without transformations; it copies the input event unchanged.

These and the syslog-focused rules share the same GoRules/zen runtime. A Web UI rule builder backed by GoRules is on the roadmap so you can compose new branches without editing JSON directly.

## Managing Rules

- Rules live in the `serviceradar-datasvc` bucket under `agents/<agent-id>/<stream>/<subject>/<rule>.json`. For the demo stack that becomes `agents/default-agent/events/events.snmp/snmp_severity.json`.
- Update or add rules with the `zen-put-rule` helper inside the `serviceradar-tools` container. Example:

  ```bash
  kubectl -n demo exec deploy/serviceradar-tools -- \
    zen-put-rule --agent default-agent --stream events \
    --subject events.snmp --rule snmp_severity \
    --file /etc/serviceradar/zen/rules/snmp_severity.json
  ```

  Substitute `passthrough` when you want to register the no-op rule for additional subjects (for example OTEL logs).

## Validate Collection

- Use `serviceradarctl poller check` to run ad-hoc queries against new devices.
- Inspect SRQL queries such as `SELECT * FROM snmp.interfaces WHERE device = '<hostname>' LIMIT 10;` to verify ingestion.
- Set up baseline alerts once metrics stabilize—see the [Troubleshooting Guide](./troubleshooting-guide.md#snmp) for common failure modes.
