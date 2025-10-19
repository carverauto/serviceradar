---
title: ServiceRadar Quickstart
---

# ServiceRadar Quickstart

Follow these condensed steps to get ServiceRadar collecting data within an hour. Each phase links to longer-form docs so you can dive deeper when needed.

## 1. Pick a Deployment Path

- **Docker Compose** – fastest path for local trials. Follow the [Docker setup guide](./docker-setup.md) to launch core, poller, web UI, and supporting services with pre-baked defaults.
- **Bare Metal** – when you want packages on dedicated hosts, start with the [Installation Guide](./installation.md) and layer on TLS, authentication, and KV configuration.
- **Kubernetes** – production-style clusters or cloud POCs. Use the [Helm configuration](./helm-configuration.md) to install charts and align values with your environment.

## 2. Bootstrap Access

1. Generate TLS material with the [Self-Signed Certificates guide](./self-signed.md) or import your existing CA chain.
2. Create initial local users and JWT settings using the [Authentication configuration](./auth-configuration.md) checklist.
3. Enable API keys for pollers and sync integrations as described in [Configuration Basics](./configuration.md#auth-and-rbac).

## 3. Ingest Device Data

Pick one telemetry channel to validate the pipeline end to end:

- **SNMP** – configure collectors by following the [SNMP ingest playbook](./snmp.md).
- **Syslog** – forward device logs to the ServiceRadar gateway via the [Syslog ingest guide](./syslog.md).
- **OTEL** – export traces and metrics toward the OTLP endpoint documented in the [OTEL integration page](./otel.md).

Once the first data source is healthy, layer on additional protocols through the [Get Data In](./snmp.md) section.

## 4. Explore the UI

- Sign in to the dashboard at `https://<web-host>` and bookmark the SRQL explorer.
- Import starter dashboards from the [Web UI configuration guide](./web-ui.md).
- Use [Service Port Map](./service-port-map.md) to verify discovered services and dependencies.

## 5. Automate Integrations

When the core deployment is stable, connect inventory and security feeds:

- Sync Armis devices with the [Armis integration doc](./armis.md).
- Pull topology from NetBox using the [NetBox integration guide](./netbox.md).
- Expose runtime data to AI assistants via the [MCP integration reference](./mcp-integration.md).

## 6. Validate Health

- Run smoketests in `cmd/poller/testdata` or your own synthetic checks to confirm alerting.
- Review the [Troubleshooting Guide](./troubleshooting-guide.md) for quick fixes to common onboarding blockers.
- Keep the demo namespace tidy with the reset steps in [Agents & Demo Operations](./agents.md).
