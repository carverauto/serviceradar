---
title: Syslog Ingest Guide
---

# Syslog Ingest Guide

ServiceRadar collects log events through a stateless gateway that forwards messages to Proton for storage and alerting. Pair this quick guide with the [Device Configuration Reference](./device-configuration.md#syslog-configuration) when onboarding new platforms.

## Provision the Gateway

1. Expose the syslog listener (`service/serviceradar-syslog`) on UDP/TCP 514. In Docker Compose, this maps to the host automatically; in Kubernetes, create a `LoadBalancer` or `NodePort`.
2. Allocate dedicated volumes if you need to buffer bursts; Proton consumes events in near real time, but disk headroom protects against traffic spikes.
3. Tag syslog inputs with `tenant`, `site`, or `device` metadata using the [Sync service configuration](./sync.md) so SRQL queries stay filterable.

## Configure Devices

- Use TLS-capable transports (TCP/TLS or RELP) where supported. When restricted to UDP, enforce ACLs and use an out-of-band management network.
- Normalize time zones to UTC to keep SRQL queries aligned with SNMP and OTEL data.
- Leverage structured data fields (RFC 5424) for network appliances that support it; ServiceRadar stores them as JSON for easier filtering.

## Event Pipeline

1. The `serviceradar-flowgger` gateway accepts syslog over UDP/TCP 514 and publishes each message to the NATS JetStream stream named `events` on the `events.syslog` subject.
2. JetStream retains the raw envelope while `serviceradar-zen` (the zen engine) consumes the same stream using the `zen-consumer` durable. The consumer appends a `.processed` suffix (for example `events.syslog.processed`) after rules execute so downstream writers can subscribe without reprocessing the original payload.
3. The `serviceradar-db-event-writer` deployment reads the `.processed` subjects and batches inserts into Proton. Because both the raw and processed subjects live in the `events` stream you can replay either layer during troubleshooting.

## Zen Rules

The default decision group for syslog chains two GoRules/zen flows that focus on Ubiquiti-style events:

- `strip_full_message` removes the duplicated `full_message` field that UniFi devices emit so only the structured payload remains.
- `cef_severity` inspects the CEF header segment and maps the embedded numeric severity into the ServiceRadar priority scale (`Low`, `Medium`, `High`, `Very High`, or `Unknown`).

You can inspect the JSON definitions in `packaging/zen/rules/` or the rendered ConfigMap `k8s/demo/base/serviceradar-zen-rules.yaml`. Future releases will surface these flows in a Web UI rule builder powered by GoRules so operators can drag-and-drop additional matchers without touching JSON.

## Managing Rules

- Rules are stored in the NATS JetStream key-value bucket `serviceradar-kv` using the key pattern `agents/<agent-id>/<stream>/<subject>/<rule>.json`. The demo agent ID is `default-agent`, stream `events`, and subject `events.syslog`.
- The `zen-put-rule` helper (packaged in the `serviceradar-tools` container) publishes rule updates. Launch the toolbox pod and run:

  ```bash
  kubectl -n demo exec deploy/serviceradar-tools -- \
    zen-put-rule --agent default-agent --stream events \
    --subject events.syslog --rule strip_full_message \
    --file /etc/serviceradar/zen/rules/strip_full_message.json
  ```

  The helper validates JSON before writing to JetStream and will create the key if it is missing.

## Parsing and Routing

- Proton still applies grok-style parsing rules after the zen engine. Customize patterns under `config/proton/syslog.rules` and redeploy Proton when you add vendors.
- Route noisy facilities (e.g., `local7.debug`) to lower retention tiers by adjusting the [Proton configuration](./proton.md#retention).
- Convert critical events into alerts through the Core API; see the [Service Port Map](./service-port-map.md#log-watchers) for sample selectors.

## Verification Checklist

- Confirm throughput via `kubectl logs deploy/serviceradar-syslog -n demo`.
- Run SRQL queries such as `SELECT message FROM syslog.events ORDER BY timestamp DESC LIMIT 20;`.
- Cross-link syslog and SNMP data in dashboards to highlight correlation during incidents.
