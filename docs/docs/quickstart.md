---
title: ServiceRadar Quickstart
---

# ServiceRadar Quickstart

Follow these condensed steps to get ServiceRadar collecting data within an hour. Each phase links to longer-form docs so you can dive deeper when needed.

## 1. Pick a Deployment Path

- **Docker Compose** – fastest path for local trials. Follow the [Docker setup guide](./docker-setup.md) to launch web-ng, core-elx, agent-gateway, and supporting services with pre-baked defaults.
- **Kubernetes** – production-style clusters or cloud POCs. Use the [Helm configuration](./helm-configuration.md) to install charts and align values with your environment.
- **Edge Agents** – onboard edge agents with the [Edge Agent Onboarding](./edge-agent-onboarding.md) flow.

## 2. Bootstrap Access

1. Generate TLS material with the [Self-Signed Certificates guide](./self-signed.md) or import your existing CA chain.
2. Sign in with the bootstrapped admin user (Helm/Docker Compose generate this for you) and review **Settings -> Authentication** to enable Direct SSO or Gateway Proxy if desired.

## 3. Ingest Device Data

Pick one telemetry channel to validate the pipeline end to end:

- **SNMP** – configure collectors by following the [SNMP ingest playbook](./snmp.md).
- **Syslog** – forward device logs to the ServiceRadar stack via the [Syslog ingest guide](./syslog.md).
- **OTEL** – export traces and metrics toward the OTLP endpoint documented in the [OTEL integration page](./otel.md).

Once the first data source is healthy, layer on additional protocols through the [Get Data In](./snmp.md) section.

## 4. Explore the UI

- Sign in to the dashboard at `https://<web-host>` and bookmark the SRQL explorer.
- Use [Tools Pod](./tools.md) to sanity check JetStream consumers and CNPG connectivity during debugging.

## 5. Automate Integrations

When the core deployment is stable, connect inventory and security feeds:

- Sync Armis devices with the [Armis integration doc](./armis.md).
- Pull topology from NetBox using the [NetBox integration guide](./netbox.md).

## 6. Validate Health

- Run smoketests (or your own synthetic checks) to confirm alerting.
- Review the [Troubleshooting Guide](./troubleshooting-guide.md) for quick fixes to common onboarding blockers.
