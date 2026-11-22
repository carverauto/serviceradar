---
title: Syslog Ingest Guide
---

# Syslog Ingest Guide

ServiceRadar collects log events through `serviceradar-log-collector`, publishes
them to NATS JetStream, and stores them in the configured telemetry backend
(StarRocks or CNPG/Timescale). The collector applies the Zen rules to syslog
itself; see [Event Pipeline](#event-pipeline). Pair this quick guide with the
[Device Configuration Reference](./device-configuration.md#syslog-configuration)
and the [Kubernetes External Ingestion](./kubernetes-ingestion.md) guide when
onboarding new platforms.

## Provision the Gateway

1. Expose `serviceradar-log-collector` on UDP 514. In Kubernetes, prefer a shared Gateway API UDP listener plus `gatewayApi.syslog.enabled` when the cluster already has a shared Envoy Gateway. Use `logCollector.externalService.enabled` only when you need a dedicated LoadBalancer or NodePort.
2. Size the collector memory budget for bursts and monitor JetStream lag. Receiving a syslog message does not by itself establish durable storage.
3. Attach `site`, `account`, or other metadata using **Settings -> Integrations** so logs stay filterable in SRQL and dashboards.

### TCP Syslog

The `serviceradar-log-collector` deployment accepts syslog over **UDP 514** and, when `logCollector.tcpCollector.enabled` is true (the chart default), **TCP 514** in the same process as OTLP. Configure the TCP listener with:

```yaml
logCollector:
  tcpCollector:
    enabled: true
    listen: "0.0.0.0:514"   # TCP
    format: "auto"            # RFC3164, RFC5424, or ClearPass standard
    framing: "line"
```

For a custom TCP listen port, set the same numeric port in
`logCollector.tcpCollector.service.ports.syslog.targetPort`. Both internal
Service names then route to that listener. Set any enabled external TCP
Service's `targetPort` to the same port as well.

TCP syslog is line-framed by default and publishes to the same NATS `events`
stream and `logs.syslog` subject as UDP through one shared Flowgger output, so
the downstream core-elx pipeline is identical. TCP provides transport delivery
and backpressure; it does not acknowledge durable storage. UDP remains useful
for lightweight, fire-and-forget exporters.

Both protocols are available on `serviceradar-log-collector`. The previous
`serviceradar-log-collector-tcp` DNS name remains a compatibility Service that
selects only pods with the TCP listener; it has no Deployment of its own.
During an upgrade, keep existing TCP clients on that alias until all primary
Service endpoints run the new image.

For a dedicated external Service, enable `logCollector.externalService.enabled`
and choose UDP and TCP independently through `ports.syslog.enabled` and
`ports.syslogTcp.enabled`. The legacy
`logCollector.tcpCollector.externalService.enabled` setting enables TCP on this
same Service. Conflicting pinned load balancer addresses fail chart rendering.
Configure replicas and resources on `logCollector`; the former TCP workload's
replica, resource and stream-replica settings are ignored. Both transports use
`logs.syslog`; a different `tcpCollector.subject` is rejected.

Docker Compose publishes both `514/udp` and `514/tcp` from its one
`log-collector` service. Standalone Flowgger configurations can retain `[input]`
and add a TCP listener using `[[inputs]]`, sharing the existing `[output]`.

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
- UDP zlib and gzip payloads are decompressed before parsing. The expanded record must be at most five times the maximum UDP packet size (65,527 bytes, so 327,635 bytes). Larger expansions are dropped; records at or under that cap are accepted.
- When senders omit the time zone (RFC 3164), set the sender timezone directly with `logCollector.rfc3164Timezone` (Helm; `input.rfc3164_timezone` in Compose). See "RFC3164 sender time zones" in the Helm chart README for the receive-time fallback that keeps fresh logs inside event-time windows.
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
also retained in the log attributes for troubleshooting. That field is the
transport peer address. A `remote_addr` entry in RFC 5424 structured data, or a
`_remote_addr` GELF extra, cannot replace it, and the collector omits the field
when it has no transport address. If a Kubernetes
load balancer or Gateway performs source NAT, the observed value may be the
load balancer or Gateway address rather than the device address. Preserve the
source address at the load balancer and Gateway layer when device-level
attribution is required.

## Event Pipeline

1. `serviceradar-log-collector` accepts syslog over UDP 514 and optional TCP 514 in one process. It follows the Zen ruleset core publishes, applies it to each message, and publishes normalized OTLP batches to the NATS JetStream stream named `events` on the `logs.normalized.syslog` subject.
2. `serviceradar_core` consumes that stream and persists the records without
   running the rules again.
3. Until the collector has received its first ruleset, or when normalization is
   turned off (`[rules] normalize = false` in the collector configuration or
   `LOG_COLLECTOR_NORMALIZE_SYSLOG=false`; the Docker Compose collector ships
   with it off), it publishes each message as GELF on
   `logs.syslog` instead, and `serviceradar_core` evaluates the Zen rules
   through a Rustler NIF before persisting it. Only these raw messages can be
   replayed through changed rules; records on `logs.normalized.syslog` already
   carry the result of the ruleset that produced them.

## Zen Rules

The default decision group for syslog chains two GoRules/zen flows that focus on Ubiquiti-style events:

- `strip_full_message` removes the duplicated `full_message` field that UniFi devices emit so only the structured payload remains.
- `cef_severity` inspects the CEF header segment and maps the embedded numeric severity into the ServiceRadar priority scale (`Low`, `Medium`, `High`, `Very High`, or `Unknown`).

A rule removes top-level fields by returning their names as an array in `serviceradar_remove_fields`, as `strip_full_message` does. Setting a top-level field to `null` does not remove it. The instruction is not stored, and a record that arrives with that field cannot use it to remove anything.

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
