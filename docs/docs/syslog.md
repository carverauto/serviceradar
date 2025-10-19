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

## Parsing and Routing

- Proton pipelines apply grok-style parsing rules. Customize patterns under `config/proton/syslog.rules` and redeploy Proton when you add vendors.
- Route noisy facilities (e.g., `local7.debug`) to lower retention tiers by adjusting the [Proton configuration](./proton.md#retention).
- Convert critical events into alerts through the Core API; see the [Service Port Map](./service-port-map.md#log-watchers) for sample selectors.

## Verification Checklist

- Confirm throughput via `kubectl logs deploy/serviceradar-syslog -n demo`.
- Run SRQL queries such as `SELECT message FROM syslog.events ORDER BY timestamp DESC LIMIT 20;`.
- Cross-link syslog and SNMP data in dashboards to highlight correlation during incidents.
