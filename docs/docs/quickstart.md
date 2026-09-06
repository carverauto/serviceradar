---
title: ServiceRadar Quickstart
---

# ServiceRadar Quickstart

Follow these condensed steps to get ServiceRadar collecting data within an hour. Each phase links to longer-form docs so you can dive deeper when needed.

:::tip ServiceRadar Cloud (hosted SaaS)
If you are onboarding a **hosted** environment rather than installing the stack
yourself, use the [Cloud Quickstart](./cloud-quickstart.md) runbook instead.
It covers control-plane network access, SSO, agent packages (RPM/DEB), collectors,
RBAC, integrations, and day-2 operations for Cloud tenants.

On Cloud, platform TLS and agent mTLS are **provisioned for you**. You install the
agent package, create an onboarding package in the UI, and follow
[host enrollment](./edge-agent-onboarding.md#3-enroll-the-host);
you do **not** generate CA material or hand-configure mTLS.
:::

## 1. Pick a Deployment Path

- **ServiceRadar Cloud** – hosted control plane and product UI. Follow the
  [Cloud Quickstart](./cloud-quickstart.md).
- **Docker Compose** – fastest path for local trials. Follow the [Docker setup guide](./docker-setup.md) to launch web-ng, core-elx, agent-gateway, and supporting services with pre-baked defaults.
- **Kubernetes** – production-style clusters or cloud POCs. Use the [Helm configuration](./helm-configuration.md) to install charts and align values with your environment.
- **Edge Agents** – onboard edge agents with the [Edge Agent Onboarding](./edge-agent-onboarding.md) flow.

## 2. Sign in and (optionally) connect SSO

1. Open the web UI. Docker Compose and Helm bootstrap an admin account for you — use those generated credentials for the first login.
2. Optionally configure **Settings → Authentication** for Direct SSO or Gateway Proxy when you are ready. See [Authentication](./auth-configuration.md). Map IdP groups under **Settings → Authorization**; see [Group Permission Mapping](./group-permission-mapping.md).
3. If this instance should send email (alert channels, dashboard reports,
   password reset), configure SMTP under **Settings -> Mail**. See
   [Outbound Mail](./outbound-mail.md). Do not put the mailbox password in
   Helm values.

:::note Certificates and agent identity
ServiceRadar automates service TLS and agent enrollment credentials in current
install paths. Cloud and standard Helm/Compose charts do **not** require you to
mint self-signed CAs or wire mTLS by hand for day-1 agent onboarding. Enroll
agents with a [UI onboarding package](./edge-agent-onboarding.md#3-enroll-the-host); the package
installs gateway identity and bootstrap config.

The [TLS & mTLS](./tls-security.md) guide remains available for advanced
self-hosted / custom CA scenarios only.
:::

## 3. Ingest Device Data

Pick one telemetry channel to validate the pipeline end to end:

- **SNMP** – configure collectors by following the [SNMP ingest playbook](./snmp.md).
- **Syslog** – forward device logs to the ServiceRadar stack via the [Syslog ingest guide](./syslog.md).
- **OTEL** – export traces and metrics toward the OTLP endpoint documented in the [OTEL integration page](./otel.md).

Once the first data source is healthy, layer on additional protocols — see
[Device Configuration](./device-configuration.md), [NetFlow](./netflow.md), and
[BGP Routing](./bgp-routing.md).

## 4. Explore and Query

- Sign in to the dashboard at `https://<web-host>` and open the SRQL explorer.
- Learn the query language with the [SRQL Tutorial](./srql-tutorial.md), then keep the
  [SRQL Cookbook](./srql-cookbook.md) handy for common queries.
- Use [Tools Pod](./tools.md) to sanity check JetStream consumers and CNPG connectivity
  during debugging (self-hosted).

## 5. Automate Integrations

When the core deployment is stable, connect inventory and security feeds:

- Sync Armis devices with the [Armis integration doc](./armis.md).
- Pull topology from NetBox using the [NetBox integration guide](./netbox.md).

## 6. Validate Health

- Run smoketests (or your own synthetic checks) to confirm alerting.
- Review the [Troubleshooting Guide](./troubleshooting-guide.md) for quick fixes to common onboarding blockers.
