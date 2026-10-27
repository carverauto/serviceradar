---
title: Navigating the Web UI
---

# Navigating the Web UI

The ServiceRadar Web UI is the main place operators monitor their environment,
investigate problems, and configure the platform. This page is a map of the main
areas to help new users find their way around. What you can see and do depends
on your role — see [Roles & Permissions](./rbac-and-roles.md).

## Monitoring & inventory

- **Dashboard** — the default landing page (your sign-in homepage may differ; see [Default Homepage After Sign-In](./auth-configuration.md#default-homepage-after-sign-in)). A high-level summary of fleet health,
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

On a device's **24h Availability Timeline**, probe observations are grouped into
30-minute buckets. Each probed address is evaluated separately: with an agent
selected, any failure in the bucket makes that address offline; without a
selection, a successful observation makes that address online. The device's
bucket is online if any address is online. Dedicated availability checks take
precedence over sweep observations in each bucket. Missing buckets remain
unknown when probe history exists.

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

### Live updates

Events, Traces, Metrics, Alerts, BMP, and BGP have a **Live** button with an
**On/Off** badge, like Logs. They open with Live off. Click Live to refresh
the current results immediately and follow incoming updates; click again to
pause automatic refreshes.

Events, Traces, Metrics, and Alerts return to the first page using the active
query when enabled. Changing their query, paging, or switching tabs turns Live
off. BMP also returns to the first page and pauses when paging. BGP keeps the
selected filters and pauses when those filters change.

Events, Traces, Metrics, Alerts, and BMP group incoming updates into refreshes
with a five-second delay. BGP refreshes on each routing observation. Alerts
refresh when an alert is created. Traces follow span ingestion and completed
summary updates; see the [OTel storage model](./otel.md#storage-model) for how
summaries become available. Live does not change the query's filters or sort
order, so only matching results appear.

## Topology & spatial views

- **Topology (Network Topology)** — an interactive map of how devices connect
  to each other. See [Network Topology](./network-topology.md).
- **NetFlow Map / Spatial** — geospatial views of traffic flows and field
  survey data. Flow panels are served from the StarRocks warehouse and report a
  warehouse-required error until the `flows` dataset is cut over; see
  [NetFlow](./netflow.md).

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
platform. Use **Search views** in the sidebar or **Ctrl+K** to find a page or
tab. Both searches include descriptions and require every typed word to match,
in any order.

Settings has three categories, shown as tabs at the top. Each one is a tree of
groups:

- **System**
  - **Platform**: Cluster Status, Jobs, Data retention, Endpoint Inventory, and
    Mail (`/settings/mail`), the deployment-wide outbound email. See
    [Outbound Mail](./outbound-mail.md).
  - **Security**, split into four sections:
    - **Users & Access**: users (`/settings/auth/users`), user groups,
      authentication (`/settings/authentication`), authorization mappings, the
      RBAC policy editor (`/settings/auth/rbac`), CLI sessions and CLI auth
      policy, and the audit trail, lockouts and change history. See
      [Authentication](./auth-configuration.md) and
      [Roles & Permissions](./rbac-and-roles.md).
    - **Credentials**: API credentials, MCP sessions, and Credentials and
      Rules (`/settings/networks/credentials`). See
      [Credentials](./credentials.md).
    - **Remote Access**: Session Recordings, Host Keys and Desktop Targets.
      See [Remote Access](./remote-access.md).
    - **Threat Intelligence**: Threat Intel
      (`/settings/networks/threat-intel`) and Vulnerability Feeds
      (`/settings/security/vulnerability-feeds`).
  - **Alerts**: Rules (`/settings/rules`; see the
    [Rule Builder](./rule-builder.md)), Anomaly Detection, and Notifications
    (`/settings/notifications`; start with the
    [Notifications Quickstart](./notification-quickstart.md)).
  - **Dashboards**: Dashboard Packages and the FieldSurvey dashboard playlist.
  - **Personal**: your Profile (`/settings/profile`). It opens from the
    account menu rather than the tree.
- **Network Services**
  - **Discovery**: sweep, visibility and SNMP profiles (`/settings/networks`,
    `/settings/networks/visibility-profiles`, `/settings/snmp`), Discovery
    Jobs, Device Enrichment, Device Hostnames, Availability Sources, Composite
    Checks, and Inventory Cleanup (`/settings/networks/inventory-cleanup`). See
    [Network Sweeps](./network-sweeps.md) and
    [Visibility Profiles](./visibility-profiles.md).
  - **Services**: Network Flows (`/settings/flows`; NetFlow directionality
    plus GeoIP / ipinfo enrichment), BGP / BMP, MTR, Integrations, and Prefix
    Tags.
- **Edge Ops**
  - **Agents**: Agent Releases, Agent Deploy (`/settings/agents/deploy`), and
    Edge Onboarding.
  - **Add-ons**: the native add-ons catalog and fleet, and the plugins manager.
  - **Fleet Health**: Host Health (`/settings/sysmon`).
  - **Sites & Collectors**: Edge Sites, Data Collectors, and Telemetry
    Onboarding.
  - **Automation**: Ansible.

Moving a page between groups never changes its URL, so bookmarks and links keep
working.

For a full hosted SaaS path (control plane + product UI), see the
[Cloud Quickstart](./cloud-quickstart.md). For agent install only, see
[Edge Agent Onboarding](./edge-agent-onboarding.md).
