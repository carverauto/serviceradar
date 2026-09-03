---
title: Syslog Ingest Guide
---

# Syslog Ingest Guide

ServiceRadar collects log events through `serviceradar-log-collector`, publishes
them to NATS JetStream, normalizes them with in-process Zen rules in core-elx,
and stores them in CNPG/Timescale. Pair this quick guide with the
[Device Configuration Reference](./device-configuration.md#syslog-configuration)
and the [Kubernetes External Ingestion](./kubernetes-ingestion.md) guide when
onboarding new platforms.

## Provision the Gateway

1. Expose `serviceradar-log-collector` on UDP 514. In Kubernetes, prefer a shared Gateway API UDP listener plus `gatewayApi.syslog.enabled` when the cluster already has a shared Envoy Gateway. Use `logCollector.externalService.enabled` only when you need a dedicated LoadBalancer or NodePort.
2. Allocate dedicated volumes if you need to buffer bursts; CNPG ingests events in near real time, but disk headroom protects against traffic spikes.
3. Attach `site`, `account`, or other metadata using **Settings -> Integrations** so logs stay filterable in SRQL and dashboards.

### TCP Syslog

The default `serviceradar-log-collector` deployment listens for syslog over **UDP 514**. To accept syslog over **TCP 514**, enable the separate `serviceradar-log-collector-tcp` deployment via `logCollector.tcpCollector.enabled` in the Helm values. It runs the same log-collector binary with only the flowgger input enabled (OTEL disabled) and a TCP-mode flowgger input:

```yaml
logCollector:
  tcpCollector:
    enabled: true
    listen: "0.0.0.0:514"   # TCP
    format: "auto"            # RFC3164, RFC5424, or ClearPass standard
    framing: "line"
```

TCP syslog is line-framed by default and publishes to the same NATS `events`
stream and `logs.syslog` subject as the UDP collector, so the downstream core-elx
pipeline is identical. Use TCP when devices need reliable delivery; UDP remains
the default for lightweight, fire-and-forget exporters.

Example Kubernetes Gateway API values:

```yaml
gatewayApi:
  enabled: true
  mode: attach
  syslog:
    enabled: true
    parentRefs:
      - group: gateway.networking.k8s.io
        kind: Gateway
        name: serviceradar-shared-gateway
        namespace: serviceradar-system
        sectionName: syslog-udp
```

Network devices should send syslog to `<SYSLOG_GATEWAY_ADDRESS>:514/UDP`. Keep the actual address in private operations material. NetFlow and sFlow stay on the flow collector address; see [Kubernetes External Ingestion](./kubernetes-ingestion.md#address-model).

## Configure Devices

- Prefer TCP or TLS transports where supported (see [TCP Syslog](#tcp-syslog)). The log-collector's flowgger input supports `udp`, `tcp`, and `tls`; it does not support RELP. When restricted to UDP, enforce ACLs and use an out-of-band management network.
- Normalize time zones to UTC to keep SRQL queries aligned with SNMP and OTEL data.
- Leverage structured data fields (RFC 5424) for network appliances that support it; ServiceRadar stores them as JSON for easier filtering.

## Accepted Formats

The default collector input format is `auto`. It tries RFC 5424, RFC 3164, and
the ClearPass standard header format for each message. ClearPass standard
messages use a full year and comma-separated milliseconds, for example
`2020-01-01 00:00:00,000 192.0.2.34 CPPM_Session_Detail ...`.

CEF, LEEF, and other opaque payloads are accepted and retained as the log body
even when ServiceRadar does not yet extract their vendor-specific fields. A
message that does not match a known header is still published with its raw
body, receive timestamp, and fallback metadata so ingestion does not silently
drop it. Explicit `rfc3164` or `rfc5424` modes remain strict and are useful
when a sender is known to emit only one format.

For ClearPass and RADIUS integrations, select RFC 5424 when available. The
ClearPass standard format is also supported when that is the format required by
the deployment.

## Source IP Preservation

For network transports, `source_ip` is the address observed by the collector.
The log detail view displays it as **Source IP**, SRQL can filter it with
`source_ip:"10.208.254.4"`, and the original Flowgger `_remote_addr` value is
also retained in the log attributes for troubleshooting. If a Kubernetes
load balancer or Gateway performs source NAT, the observed value may be the
load balancer or Gateway address rather than the device address. Preserve the
source address at the load balancer and Gateway layer when device-level
attribution is required.

## Event Pipeline

1. `serviceradar-log-collector` accepts syslog over UDP 514 (or TCP 514 via the optional `serviceradar-log-collector-tcp` deployment) and publishes each message to the NATS JetStream stream named `events` on the `logs.syslog` subject.
2. JetStream retains the raw envelope while `serviceradar_core` consumes the same
   stream, evaluates the bundled Zen rules through a Rustler NIF, and persists
   the normalized log record.
3. Because the raw subject remains in the `events` stream, you can replay
   ingestion after adjusting code or bundled rules.

## Zen Rules

The default decision group for syslog chains two GoRules/zen flows that focus on Ubiquiti-style events:

- `strip_full_message` removes the duplicated `full_message` field that UniFi devices emit so only the structured payload remains.
- `cef_severity` inspects the CEF header segment and maps the embedded numeric severity into the ServiceRadar priority scale (`Low`, `Medium`, `High`, `Very High`, or `Unknown`).

You can inspect the bundled JSON definitions under
`elixir/serviceradar_core/priv/zen/rules/`. See the
[Rule Builder](./rule-builder.md) guide for the UI used to manage rule
templates.

## Managing Rules

- Use **Settings -> Events** to manage rule templates for syslog.
- In normal operation, rule distribution is handled by the control plane. You
  should not need to write NATS keys by hand.

## Parsing and Routing

- Core-elx now owns normalization before data lands in CNPG. Update the bundled
  rule files and redeploy core-elx to change default normalization behavior.
- Route noisy facilities (e.g., `local7.debug`) to lower retention tiers by
  adjusting ingestion mappings or by downsampling in CNPG (see the
  [CNPG monitoring guide](./cnpg-monitoring.md) for helper queries).
- Convert critical events into alerts through the Core API; use the Rule Builder UI to promote and route events (see [Rule Builder](./rule-builder.md)).

## Verification Checklist

- If running in Kubernetes, confirm throughput via `kubectl logs deploy/serviceradar-log-collector -n <namespace> --since=10m`.
- If using Gateway API, confirm the route is accepted with `kubectl describe udproute -n <namespace> serviceradar-syslog`.
- Syslog logs land in the `logs` hypertable (CNPG/Timescale). Filter on `source = 'syslog'`, for example:

  ```sql
  SELECT timestamp, body
  FROM logs
  WHERE source = 'syslog'
  ORDER BY timestamp DESC
  LIMIT 20;
  ```
- Verify the collector-observed address with `SELECT timestamp, source_ip, body FROM logs WHERE source = 'syslog' ORDER BY timestamp DESC LIMIT 20;`.
- Cross-link syslog and SNMP data in dashboards to highlight correlation during incidents.
