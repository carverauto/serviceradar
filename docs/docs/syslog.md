---
title: Syslog Ingest Guide
---

# Syslog Ingest Guide

ServiceRadar collects log events through `serviceradar-log-collector`, publishes them to NATS JetStream, normalizes them with Zen rules, and stores processed events in CNPG/Timescale. Pair this quick guide with the [Device Configuration Reference](./device-configuration.md#syslog-configuration) and the [Kubernetes External Ingestion](./kubernetes-ingestion.md) guide when onboarding new platforms.

## Provision the Gateway

1. Expose `serviceradar-log-collector` on UDP 514. In Kubernetes, prefer a shared Gateway API UDP listener plus `gatewayApi.syslog.enabled` when the cluster already has a shared Envoy Gateway. Use `logCollector.externalService.enabled` only when you need a dedicated LoadBalancer or NodePort.
2. Allocate dedicated volumes if you need to buffer bursts; CNPG ingests events in near real time, but disk headroom protects against traffic spikes.
3. Attach `site`, `account`, or other metadata using Zen rules or **Settings → Integrations** so logs stay filterable in SRQL and dashboards.

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

In the ServiceRadar demo environment, network devices should send syslog to `23.138.124.5:514/UDP`. NetFlow and sFlow stay on the flow collector address; see [Kubernetes External Ingestion](./kubernetes-ingestion.md#address-model).

## Configure Devices

- Use TLS-capable transports (TCP/TLS or RELP) where supported. When restricted to UDP, enforce ACLs and use an out-of-band management network.
- Normalize time zones to UTC to keep SRQL queries aligned with SNMP and OTEL data.
- Leverage structured data fields (RFC 5424) for network appliances that support it; ServiceRadar stores them as JSON for easier filtering.

## Event Pipeline

1. `serviceradar-log-collector` accepts syslog over UDP 514 and publishes each message to the NATS JetStream stream named `events` on the `logs.syslog` subject.
2. JetStream retains the raw envelope while `serviceradar-zen` (the zen engine) consumes the same stream using the `zen-consumer` durable. The consumer appends a `.processed` suffix (for example `logs.syslog.processed`) after rules execute so downstream writers can subscribe without reprocessing the original payload.
3. The `serviceradar-db-event-writer` deployment reads the `.processed` subjects and batches inserts into the CNPG/Timescale tables. Because both the raw and processed subjects live in the `events` stream you can replay either layer during troubleshooting.

## Zen Rules

The default decision group for syslog chains two GoRules/zen flows that focus on Ubiquiti-style events:

- `strip_full_message` removes the duplicated `full_message` field that UniFi devices emit so only the structured payload remains.
- `cef_severity` inspects the CEF header segment and maps the embedded numeric severity into the ServiceRadar priority scale (`Low`, `Medium`, `High`, `Very High`, or `Unknown`).

You can inspect the JSON definitions in `build/packaging/zen/rules/` (and the rendered Helm ConfigMap in your cluster). The Rule Builder UI now manages these flows without touching JSON; see the [Rule Builder](./rule-builder.md) guide.

## Managing Rules

- Use **Settings → Events** to manage Zen normalization rules for syslog.
- In normal operation, rule distribution is handled by the control plane. You should not need to write NATS keys by hand.
- For advanced debugging, the `zen-put-rule` helper (packaged in the `serviceradar-tools` container) can publish rule updates. Launch the toolbox pod and run:

  ```bash
  kubectl -n <namespace> exec deploy/serviceradar-tools -- \
    zen-put-rule --agent default-agent --stream events \
    --subject logs.syslog --rule strip_full_message \
    --file /etc/serviceradar/zen/rules/strip_full_message.json
  ```

  The helper validates JSON before writing to JetStream and will create the key if it is missing.

## Parsing and Routing

- The zen engine now owns all parsing before data lands in CNPG. Add or update GoRules flows under `build/packaging/zen/rules/` and redeploy `serviceradar-zen` to change normalization.
- Route noisy facilities (e.g., `local7.debug`) to lower retention tiers by adjusting db-event-writer stream mappings or by downsampling in CNPG (see the [CNPG monitoring guide](./cnpg-monitoring.md) for helper queries).
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
- Cross-link syslog and SNMP data in dashboards to highlight correlation during incidents.
