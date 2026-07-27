---
title: Navigating the Web UI
---

# Navigating the Web UI

The ServiceRadar Web UI is the main place operators monitor their environment,
investigate problems, and configure the platform. This page is a map of the main
areas to help new users find their way around. What you can see and do depends
on your role — see [Roles & Permissions](./rbac-and-roles.md).

## Monitoring & inventory

- **Dashboard** — the landing page. A high-level summary of fleet health,
  recent activity, and key metrics.
- **Devices** — the device inventory. Browse, filter, and search all monitored
  devices; open a device to see its details, interfaces, services, metrics, and
  available remote-access actions.
- **Interfaces** — a fleet-wide view of network interfaces across all devices,
  useful for spotting interface-level problems.
- **Agents** — the agents currently connected to this instance, with their
  status and the checks they are running.
- **Gateways** — the agent-gateways that agents push status through, with
  connection and health information.

## Events & alerts

- **Events** — the raw event stream ingested by ServiceRadar.
- **Alerts** — actionable alerts raised by rules. Helpdesk and operator users
  can acknowledge and resolve alerts here.

## Observability

The **Observability** section collects telemetry data:

- **Logs** — searchable log records with detail views.
- **Traces** — distributed traces and individual span detail.
- **BMP / BGP** — BGP Monitoring Protocol feeds and routing data. See
  [BGP Routing](./bgp-routing.md).
- **Camera relays** — camera relay streams and the analysis workers that
  process them.

## Topology & spatial views

- **Topology (Network Topology)** — an interactive map of how devices connect
  to each other. See [Network Topology](./network-topology.md).
- **NetFlow Map / Spatial** — geospatial views of traffic flows and field
  survey data.

## Diagnostics

- **Diagnostics → MTR** — run interactive traceroutes (My Traceroute) to a
  target, review past traces, and compare two traces side by side. For scheduled
  MTR checks, see [Agent Configuration](./agent-configuration.md).

## Querying your data

Most list views support **SRQL**, the ServiceRadar Query Language, for
filtering and searching. To learn it, see the
[SRQL Tutorial](./srql-tutorial.md).

## Dashboards and analytics

Open **Dashboards** to find dashboards you own, dashboards shared with you, and
dashboards available through your groups. Open **Analytics** to create a
self-authored dashboard from SRQL source queries, guided visual outputs, and a
drag-and-drop canvas. See [Self-Authored Dashboards](./self-authored-dashboards.md)
for the full workflow.

## Settings

The **Settings** tree is where administrators and operators configure the
platform. Common sections include:

- **Auth / Users** — manage users (`/settings/auth/users`), authentication
  providers (`/settings/authentication`), and RBAC policy profiles
  (`/settings/auth/rbac`). See [Authentication](./auth-configuration.md) and
  [Roles & Permissions](./rbac-and-roles.md).
- **Networks** — sweep profiles (`/settings/networks`), visibility profiles,
  discovery jobs, device enrichment, credential rules, remote-access host keys
  and desktop targets, BMP, MTR profiles, field surveys, integrations, prefix
  tags, and threat intel. See [Network Sweeps](./network-sweeps.md).
- **Flows** — NetFlow directionality plus GeoIP / ipinfo enrichment
  (`/settings/flows`).
- **SNMP / Host Health** — SNMP profiles (`/settings/snmp`) and Sysmon host
  metrics (`/settings/sysmon`).
- **Rules** — Zen log normalization, event promotion, and alerts
  (`/settings/rules`). See the [Rule Builder](./rule-builder.md).
- **Agents** — deploy (`/settings/agents/deploy`), releases, plugins manager,
  and native add-ons catalog/fleet.
- **API credentials & CLI sessions** — API keys for programmatic access and
  management of `serviceradar-cli` device sessions.
- **Audit** — version history, the security-event stream, and auth lockouts.

For a full hosted SaaS path (control plane + product UI), see the
[Cloud Quickstart](./cloud-quickstart.md). For agent install only, see
[Edge Agent Onboarding](./edge-agent-onboarding.md).
