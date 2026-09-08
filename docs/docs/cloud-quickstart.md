---
title: ServiceRadar Cloud Quickstart
description: Hosted SaaS runbook—from a provisioned environment to agents, SSO, collectors, security feeds, and day-2 operations.
sidebar_label: Cloud Quickstart
---

# ServiceRadar Cloud Quickstart

A practical **hosted (SaaS) runbook**: take a new ServiceRadar Cloud environment from
provisioned to useful in production. This page is an ordered path with the right UI
locations and defaults. It does **not** replace the deep topic guides—follow the
links when you need full reference material.

:::tip Who this is for
Tenant admins and platform operators on **ServiceRadar Cloud**.

- **Control plane:** [control.serviceradar.cloud](https://control.serviceradar.cloud)
  (billing, workspaces, network access / firewall policy)
- **Product UI (web-ng):** your environment’s hosted ServiceRadar console (agents,
  inventory, observability, settings)

Self-hosted Docker or Helm installs should start with the general
[Quickstart](./quickstart.md) instead.
:::

## What Cloud operates vs what you own

| Layer | Operated by | You own |
| --- | --- | --- |
| Core, web UI, collectors, CNPG, NATS, platform TLS | ServiceRadar Cloud | Plan, region, capacity, network access policy |
| Outbound platform email (invites, resets, many alerts) | ServiceRadar Cloud | Recipients and alert rules—not SMTP for the platform mailbox |
| Edge agents on customer hosts | You | Install, enroll, keep healthy, staged upgrades |
| Devices, credentials, sweeps, discovery, integrations | You | Configuration in the product UI |
| Identity | You + IdP | SSO providers; **local user rows still required for RBAC** |

---

## Table of contents

1. [Before you start](#1-before-you-start)
2. [Control plane: open the workspace](#2-control-plane-open-the-workspace)
3. [Control plane: network access (firewall)](#3-control-plane-network-access-firewall)
4. [Product UI: users, SSO, and RBAC](#4-product-ui-users-sso-and-rbac)
5. [Install and enroll agents](#5-install-and-enroll-agents)
6. [Keep agents updated](#6-keep-agents-updated)
7. [Wasm plugins vs native add-ons](#7-wasm-plugins-vs-native-add-ons)
8. [Edge Ops: host health and visibility](#8-edge-ops-host-health-and-visibility)
9. [Inventory: devices, credentials, discovery, sweeps, SNMP](#9-inventory-devices-credentials-discovery-sweeps-snmp)
10. [Point devices at Cloud collectors](#10-point-devices-at-cloud-collectors)
11. [GeoIP and flow enrichment](#11-geoip-and-flow-enrichment)
12. [Log normalization (Zen) and alerts](#12-log-normalization-zen-and-alerts)
13. [Threat intelligence and vulnerability feeds](#13-threat-intelligence-and-vulnerability-feeds)
14. [Integrations: Armis, NetBox, Ansible](#14-integrations-armis-netbox-ansible)
15. [Telemetry onboarding (OTLP)](#15-telemetry-onboarding-otlp)
16. [First-week checklist](#16-first-week-checklist)
17. [Day-2 operations](#17-day-2-operations)
18. [Related docs](#18-related-docs)

---

## 1. Before you start

Complete signup and wait until the environment is **Ready** at
[control.serviceradar.cloud](https://control.serviceradar.cloud)
(pricing → signup → provisioning → workspace live).

You will need:

1. Access to the control-plane account that owns the tenant.
2. At least one Linux host (or VM) that can:
   - Reach the hosted **agent-gateway** outbound (HTTPS/gRPC path your environment
     publishes — after enroll, the agent uses automated mutual TLS; you do not
     install CA bundles by hand).
   - Reach the devices you want to poll (SNMP, SSH, etc.) from that host.
3. A private ops note for **listener hostnames / addresses** once network access
   publishes them (gateway, syslog, NetFlow, traps, BMP). Public docs never pin
   long-lived customer collector IPs—copy them from the control-plane network
   page and product **Telemetry Onboarding** when your environment is live.
4. A short list of who should be `admin` vs day-to-day `operator` / `viewer`.

:::tip No manual TLS bootstrap
On Cloud, **platform certificates and agent identity are automated**. Do not
generate self-signed CAs, distribute root certs to hosts, or hand-edit mTLS
paths for day-1 onboarding. Install the agent package → create an onboarding
package in the UI, then follow
[host enrollment](./edge-agent-onboarding.md#3-enroll-the-host) with the token. Enrollment
writes gateway identity and bootstrap config for you.
:::

:::note Package-managed agents
Production fleets should use the **package-managed** agent (DEB/RPM from the
release train). That layout includes the updater, seed binary, and runtime root
expected by [Agent Release Management](./agent-release-management.md).
:::

---

## 2. Control plane: open the workspace

**Where:** [control.serviceradar.cloud](https://control.serviceradar.cloud) →
**Workspaces** (`/tenants`).

1. Select the workspace (tenant) that finished provisioning.
2. Use **Open ServiceRadar** (or the equivalent open-environment action) to enter
   the product UI for that environment.
3. Confirm you can load the product **Dashboard**.

Related control-plane links for the same tenant:

- **Network access** — `/tenants/<slug>/network` (next section)
- **Billing / status / support** — as shown on the tenant portal for your plan

---

## 3. Control plane: network access (firewall)

Hosted environments default to a **closed / restricted** public edge. Configure
who may reach the Web console and telemetry listeners **before** you aim field
exporters at Cloud.

**Where:** Control plane → tenant → **Network access**  
`/tenants/<slug>/network`

### Workflow

1. **Create source groups**  
   Named sets of public IPs or CIDRs (office egress NAT, DC management, jump
   hosts). One address or CIDR per line; IPv4 singles are stored as exact hosts.

2. **Assign groups to listeners (exposures)**  
   Each enabled ServiceRadar endpoint appears with protocol and port (for
   example Web console HTTPS, agent-gateway, syslog, NetFlow, traps, BMP). Bind
   the right source groups to each listener. Some listeners may be coupled on a
   shared edge—the UI explains when sources are unioned.

3. **Web console**  
   The secure default is closed. Prefer restricted access (selected source
   groups) over “access from anywhere.”

4. **Preview → publish → verify**  
   Review the policy preview, publish, and wait until verification completes.
   Policy changes can lock the UI while a revision is in flight.

### Guidance

- Restrict **UDP** collectors (syslog `514`, NetFlow `2055`, traps `162`) to known
  exporter networks whenever possible.
- After a publish, re-check agent enrollment and one device export path.
- Revisit this page when office egress or DC NAT ranges change.

Port patterns (architecture reference, not your specific hostnames):
[Service Port Map](./service-port-map.md),
[Kubernetes Ingress Services](./service-ports.md).

---

## 4. Product UI: users, SSO, and RBAC

All of this section is in the **product UI**, not the control plane.

### 4.1 First admin session

Sign in with the account created at signup (email/password and any linked social
login). Land on the dashboard and open **Settings**.

### 4.2 Local user records still exist with SSO

:::important Local accounts still exist with SSO
ServiceRadar attaches **roles and custom RBAC profiles to user records** in the
product database. Even if people only ever use “Sign in with SSO,” each person
still needs a user row so you can audit actions against a stable identity.

You do **not** have to pre-create every row by hand. In
**Settings → Authorization**, turn on **Create accounts on first SSO login**
and map IdP groups to a built-in role and/or a role profile. The first
successful SSO sign-in creates the local account. See
[Group Permission Mapping](./group-permission-mapping.md).

Still keep at least one **local password** admin (or enable local password on a
break-glass account) for IdP outages. See
[Authentication — local password with SSO](./auth-configuration.md#local-password-login-with-sso).
:::

### 4.3 Configure SSO (OIDC / SAML)

**Where:** **Settings → Authentication** (`/settings/authentication`)

1. Choose **Direct SSO** (OIDC or SAML).
2. **OIDC** — discovery URL, client ID, client secret.  
   Redirect URI: `https://<your-web-host>/auth/oidc/callback`
3. **SAML** — IdP metadata URL or XML.  
   - ACS: `https://<your-web-host>/auth/saml/consume`  
   - SP metadata: `https://<your-web-host>/auth/saml/metadata`
4. Map claims: `email` (required), plus `name` and `sub` when available.
5. In **Settings → Authorization**, turn on first-SSO account creation if you
   do not want to pre-create users, and add group → role / role-profile mappings.
6. Test with a non-admin account first; confirm the assigned role and profile
   after login.

Full detail: [Authentication](./auth-configuration.md) and
[Group Permission Mapping](./group-permission-mapping.md).

### 4.4 Build and assign RBAC profiles

**Where:**

| Task | UI | Path |
| --- | --- | --- |
| Permission catalog & custom profiles | **Settings → Policy Editor** | `/settings/auth/rbac` |
| Assign roles to people | **Settings → Users** | `/settings/auth/users` |
| Map IdP groups to roles and profiles | **Settings → Authorization** | `/settings/auth/authorization` |

Built-in roles (increasing privilege): `viewer` → `helpdesk` → `operator` → `admin`.

| Audience | Starting role |
| --- | --- |
| Read-only stakeholders | `viewer` |
| NOC / first-line | `helpdesk` |
| Network/ops who change inventory and rules | `operator` |
| Platform owners (SSO, credentials, plugins, agents) | `admin` (few accounts) |

Create a **custom role profile** when a team needs a mix that does not match a
built-in role. See [Roles & Permissions](./rbac-and-roles.md).

### 4.5 Email on Cloud

Outbound platform mail (password reset, many notifications) is **already
configured** for hosted environments. You do **not** need to stand up SMTP for
ServiceRadar Cloud to deliver those messages.

Operators with `settings.mail.manage` can still inspect **Settings → Mail**
(`/settings/mail`) if your tenant exposes overrides. Leave platform defaults
alone unless support directs a change.

---

## 5. Install and enroll agents

Agents run **on your infrastructure** and connect **outbound** to the hosted
agent-gateway. The enroll flow provisions agent credentials and mTLS material
automatically — there is no separate certificate step.

### 5.1 Download packages

Release assets (DEB, RPM, and signed agent runtime artifacts):

**[https://github.com/carverauto/serviceradar/releases](https://github.com/carverauto/serviceradar/releases)**

The product UI links the same page from **Settings → Agent Deploy**. Prefer the
latest stable release train for production.

Typical package names (version varies by release):

| Format | Example pattern |
| --- | --- |
| Debian/Ubuntu | `serviceradar-agent_<version>.deb` |
| RHEL family | `serviceradar-agent` RPM from the same release |
| Managed runtime (rollouts) | `serviceradar-agent_<version>_linux_amd64.tar.gz` plus signed manifest assets |

### 5.2 Install (Debian / Ubuntu)

```bash
# Download the .deb for your version/arch from the releases page, then:
sudo apt-get update
sudo apt-get install -y ./serviceradar-agent_*.deb

# Confirm the unit
systemctl status serviceradar-agent --no-pager
```

### 5.3 Install (RHEL / Alma / Rocky / Fedora)

```bash
# Download the .rpm for your version/arch from the releases page, then:
sudo dnf install -y ./serviceradar-agent-*.rpm
# or: sudo rpm -Uvh ./serviceradar-agent-*.rpm

systemctl status serviceradar-agent --no-pager
```

The package installs `serviceradar-agent`, the [CLI](./cli-reference.md#where-the-binary-lives),
the package-managed updater, and the systemd unit `serviceradar-agent.service`.
Confirm the CLI using the [installation check](./edge-agent-onboarding.md#1-install-the-agent-rpmdeb).

### 5.4 Create a package and enroll (UI)

**Where:** **Settings → Agent Deploy** (`/settings/agents/deploy`)

Before issuing packages, the environment's canonical public web origin must be
configured, as must the distinct agent-gateway endpoint. ServiceRadar Cloud
provisioning normally supplies both. For a chart-managed environment with a
dedicated agent-gateway address, configure them explicitly:

```yaml
webNg:
  host: <YOUR_SERVICERADAR_WEB_HOST>
  publicUrl: https://<YOUR_SERVICERADAR_WEB_HOST>
  gatewayAddress: <YOUR_AGENT_GATEWAY_HOST>:50052

agentGateway:
  publicHostname: <YOUR_AGENT_GATEWAY_HOST>
```

`webNg.publicUrl` is embedded in signed onboarding tokens and is used to
download the bundle over HTTPS. The bundle separately contains
`gateway_addr`, derived from `webNg.gatewayAddress`, for the agent's long-lived
mTLS gRPC connection. The public gateway hostname must resolve to an endpoint
that accepts TCP `50052`, and the certificate presented there must cover that
hostname. `agentGateway.publicHostname` should use the same name so artifact
delivery on `50053` stays aligned with the gRPC endpoint.

If a generated command contains an in-cluster name such as
`https://serviceradar-web-ng`, stop and have the environment operator correct
`webNg.host` and `webNg.publicUrl`, then create a new package. If the command is
correct but the enrolled agent tries the web hostname on `50052`, correct
`webNg.gatewayAddress` and `agentGateway.publicHostname` and issue a new
package. An explicit `--core-url` can rescue a stale token download; it does not
replace the bundle's gRPC address.

1. Click **Create Agent Package** (opens edge package creation for
   `component_type=agent`, under `/admin/edge-packages/new`).
2. Complete the package form (label, gateway defaults, partition/site as prompted).
3. Copy the **edgepkg** token from the success modal.
4. On the host, follow [Enroll The Host](./edge-agent-onboarding.md#3-enroll-the-host)
   using the public web origin and copied token (the token is a secret).
5. Confirm the agent appears **Online** under **Agents** in the product UI.

What enroll does for you:

- Installs gateway identity and bootstrap config (automated mTLS — no CA hand-off).
- Points the agent at the environment gateway derived from your deployment.

Notes:

- Enrollment requires verified HTTPS (no insecure TLS bypass flag).
- A signed token normally carries the public web origin. An explicit
  `--core-url` takes precedence over that embedded origin, which is useful for
  recovering from a stale hostname; it is still required to use HTTPS.
- After download, the agent connects to the separate gateway address carried in
  the bundle. The deployment can publish `50052`/`50053` through a dedicated L4
  LoadBalancer or through explicitly configured Gateway API TCP listeners and
  routes. A web-only `80`/`443` Gateway is insufficient.
- Treat the token as a secret; create a new package to re-enroll.
- Deeper walkthrough: [Edge Agent Onboarding](./edge-agent-onboarding.md).

### 5.5 Verify connectivity

On the host:

```bash
sudo journalctl -u serviceradar-agent -n 100 --no-pager
```

In the UI: last-seen timestamp updating, no persistent offline state.

If enrollment reports success but the agent stays offline, inspect
`gateway_addr` in `/etc/serviceradar/agent.json` and test outbound TCP
connectivity to that exact host and port. Do not test only the web URL: HTTPS
enrollment and the subsequent mTLS gRPC session are separate network paths.

---

## 6. Keep agents updated

**Where:** **Settings → Agent Releases** (`/settings/agents/releases`)

1. Import a signed repository release (or publish when your workflow requires it).
2. Create a **canary rollout** to a small explicit cohort (`batch_size: 1` is fine).
3. Watch version distribution and health; **pause** on verification or restart failures.
4. Expand only after the canary is healthy.

Package-managed agents verify signed manifests and stage artifacts through the
gateway. Prefer staged rollouts over fleet-wide pushes.

Full runbook: [Agent Release Management](./agent-release-management.md).

---

## 7. Wasm plugins vs native add-ons

Do not conflate these extension mechanisms.

| | **Wasm plugins** | **Native add-ons** |
| --- | --- | --- |
| UI | **Settings → Plugins Manager** (`/settings/agents/plugins`) | **Settings → Add-ons Catalog** (`/settings/agents/addons`) and **Add-on Fleet** (`/settings/agents/addons/fleet`) |
| Runtime | Sandboxed Wasm (`wazero`) | Host process / sidecar / systemd unit |
| Typical uses | AWX bridge, custom checks, OTX edge collector | `netprobe`, `workload-identity`, `powerdns` |
| **Update model** | **Manual** — import/stage, approve, assign/promote each package version in the UI | **Managed tracking** — first-party packages can track the newest **approved** compatible version with a health-gated rollout; pins stay manual |

### Wasm plugins (manual lifecycle)

1. Import or stage a signed plugin package.
2. Review capabilities and allowlists; **approve**.
3. Assign the plugin (and schedules/actions) to the agents that need it.
4. When a new version ships, **repeat** import → approve → assign. Agents do not
   silently replace Wasm packages without operator action.

Overview: [Wasm Plugins](./wasm-plugins.md). Authoring lives on the
[developer portal](https://developer.serviceradar.cloud).

### Native add-ons (managed lifecycle)

1. Open **Add-ons Catalog** and confirm the package is imported/approved  
   (first-party Cloud packages are often auto-approved under deployment trust policy).
2. Assign to the correct agents from the catalog/fleet views.
3. Confirm health on the agent detail page and add-on fleet status.

**Targeting rules that matter on Cloud:**

- Run **netprobe** / **workload-identity** on **host agents** (worker nodes), not on
  the in-cluster `k8s-agent` pod.
- Privileged host collectors expect the package-managed agent + systemd model.

Deep dive: [Native Add-ons](./native-addons.md),
[Host Network Visibility](./netprobe.md),
[Workload Identity](./workload-identity.md).

---

## 8. Edge Ops: host health and visibility

After agents are online, enable collection from the product UI (no host-side
config files for these first-party paths).

### 8.1 Host Health (Sysmon)

**Where:** **Settings → Host Health** (`/settings/sysmon`)

Sysmon profiles control CPU, memory, disk, network, and process metrics from
enrolled agents.

1. Create a baseline profile (name, sample interval, metrics, disk paths).
2. Set targeting (for example SRQL `in:devices` or a narrower device query).
3. Save; agents pull updated config via the normal push path.

See [Sysmon Profiles](./sysmon-profiles.md).

### 8.2 Visibility profiles (passive fingerprint / capture)

**Where:** **Settings → Visibility Profiles**  
(`/settings/networks/visibility-profiles`)

Visibility profiles configure **what the agent captures and fingerprints** on
selected devices/hosts: interfaces, sample interval, TCP/TLS/HTTP fingerprint
capabilities, DPI, flow-related options, process snapshots, and retention.

1. Create a profile with a target query (defaults toward `in:devices` when empty).
2. Enable only the capabilities you need (start narrow).
3. Enable the profile and verify evidence in fingerprint / device views.

This is related to—but not the same as—the **netprobe** native add-on. Netprobe
is the privileged host collector; visibility profiles shape how agent-side
visibility/fingerprint config is applied. See
[Visibility Profiles](./visibility-profiles.md) and
[Fingerprint Architecture](./fingerprint-architecture.md).

### 8.3 Netprobe (process-attributed host network)

1. Assign the **netprobe** add-on (**Settings → Add-ons Catalog**).
2. Target host agents that own the kernel/interfaces you care about.
3. Use **Observability → Attributed Flows** (and related views) once data flows.

See [Host Network Visibility](./netprobe.md).

### 8.4 Edge sites

**Where:** **Edge Sites** (`/admin/edge-sites`)

Group agents by geography or boundary so sweeps, credentials, and rollouts stay
scoped as the fleet grows.

---

## 9. Inventory: devices, credentials, discovery, sweeps, SNMP

### 9.1 Add devices

| Path | How |
| --- | --- |
| Automatic | Sweeps, discovery, integrations (Armis/NetBox), agent-reported hosts |
| Manual | **Devices** (`/devices`) → create device (type, IPs, tags) |

See [Device Configuration](./device-configuration.md) and
[Navigating the Web UI](./web-ui-overview.md).

### 9.2 Credential rules

**Where:** **Settings -> Networks -> Credential Rules** (`/settings/networks/credentials`)

Every integration credential lives here, encrypted, and reaches a plugin only as a
short-lived scoped grant. Two objects: a **credential** holds the material, a
**rule** binds it to a provider, a purpose, a set of targets, and one edge scope.

1. **New Credential** -> pick `<provider> - <auth method>` and fill in the fields
   the provider declares.
2. **New Rule** -> pick the provider, choose the credential, set purpose, scope,
   target query, TLS policy, and allowed ports.
3. **Preview** before enabling: In Scope, not Matched, is the number that matters.

Some providers are credential-only and take no rule -- AWX binds on a controller,
VulnCheck on a feed, SNMP on a profile.

Full model, per-provider setup (Proxmox, UniFi Protect, Axis, AWX/AAP, NetBox,
VulnCheck, SNMP), and symptom-to-cause troubleshooting:
[Credential Management](./credentials.md).

### 9.3 Discovery jobs

**Where:** **Settings → Discovery Jobs** (`/settings/networks/discovery`)

Enable discovery so agents map interfaces and topology into inventory and the
graph. See [Discovery Guide](./discovery.md).

### 9.4 Sweep profiles and groups

**Where:** **Settings → Sweep Profiles** (`/settings/networks`)

1. Create a **scanner profile** (ports, modes, timeouts, concurrency).
2. Create a **sweep group** (inventory match and/or static CIDRs, schedule,
   optional agent/partition scope).
3. Enable the group; verify results under devices / sweep views.

Modes include `tcp` (SYN), `tcp_connect`, and `icmp`. Tune SYN carefully before
large CIDRs ([SYN scanner tuning](./syn-scanner-tuning.md)).

See [Network Sweeps](./network-sweeps.md).

### 9.5 SNMP profiles

**Where:** **Settings → SNMP Profiles** (`/settings/snmp`)

1. Create a profile with a target query.
2. Bind credential rules (v2c community or SNMPv3).
3. Enable polling; verify metrics and inventory fields.

Device-side examples: [Device Configuration](./device-configuration.md),
[SNMP Ingest](./snmp.md).

### 9.6 Device enrichment (optional)

**Where:** **Settings → Device Enrichment**  
(`/settings/networks/device-enrichment`)

Asset enrichment criteria and device profile rules after the inventory base is
stable.

---

## 10. Point devices at Cloud collectors

Copy **listener hostnames / addresses** from control-plane network access (and
product telemetry onboarding). Do not invent collector IPs from public docs.

| Telemetry | Default port | Protocol | Configure on |
| --- | ---: | --- | --- |
| Syslog | 514 | UDP (TCP optional where enabled) | Routers, firewalls, Linux rsyslog/syslog-ng |
| SNMP traps | 162 | UDP | Devices that emit traps |
| NetFlow / IPFIX | 2055 | UDP | Flow exporters |
| sFlow | 6343 | UDP | sFlow agents |
| BMP (BGP) | 11019 | TCP | BMP monitoring stations on routers |
| Agent gateway | 50052 | gRPC (mTLS automatic after enroll) | Agents only (outbound from host) |
| OTLP | per environment | HTTPS / gRPC | App / mesh exporters |

**Your-side firewall:**

- Allow **outbound** from exporters and agents to the Cloud listeners you use.
- Allow **inbound** on management networks only as needed for SNMP (and similar)
  **from your agents** toward devices.

### Syslog

Point devices at `<SYSLOG_LISTENER>:514`. Prefer RFC 5424 when available.  
See [Syslog Ingest](./syslog.md).

### SNMP polling vs traps

- **Polling:** agents poll UDP/161 using SNMP profiles + credential rules.
- **Traps:** devices send to `<TRAP_LISTENER>:162`.

See [SNMP](./snmp.md).

### NetFlow / IPFIX / sFlow

Export to `<FLOW_LISTENER>:2055` (and `:6343` for sFlow). Prefer stable exporter
affinity for NetFlow v9 templates.  
See [NetFlow](./netflow.md).

### BMP (BGP Monitoring Protocol)

Point the router’s BMP station at `<BMP_LISTENER>:11019/TCP`. Restrict sources to
routing infrastructure only.

Inspect sessions under **Settings → BGP / BMP** (`/settings/networks/bmp`).  
Flow-derived BGP analytics and BMP notes: [BGP Routing](./bgp-routing.md).

### MTR profiles

**Where:** **Settings → MTR** (`/settings/networks/mtr`)

Create scheduled / diagnostic MTR profiles for path baselining. Interactive
traces also live under **Diagnostics → MTR**.

---

## 11. GeoIP and flow enrichment

**Where:** **Settings → Network Flows** (`/settings/flows`)

Hosted environments enrich flows with **local MMDB** data (not per-IP HTTP on the
hot path):

1. **GeoIP (GeoLite2 MMDB)**  
   Enable GeoIP enrichment. Use **Run MMDB refresh** if the cache is empty or
   stale. Status fields show last success / last error.

2. **ipinfo.io/lite**  
   Optionally enable ipinfo enrichment, provide an API key for MMDB
   download/refresh, and run **ipinfo MMDB refresh** when needed.

Enrichment surfaces on flow and log detail views (GeoIP / ASN panels). Prefix tags
are separate under **Settings → Prefix Tags** (`/settings/networks/prefix-tags`).

---

## 12. Log normalization (Zen) and alerts

Platform email is already wired on Cloud. You still define **what** becomes an
alert.

**Where:** **Settings → Rules** (`/settings/rules`)  
(UI page title is **Events**; tabs for logs / events / alerts.)

| Tab | Purpose |
| --- | --- |
| **Logs** (`?tab=logs`) | **Zen** log normalization — subjects such as `logs.syslog`, `logs.snmp`, `logs.otel` |
| **Events** (`?tab=events`) | Promotion rules (logs → OCSF events) |
| **Alerts** (`?tab=alerts`) | Stateful alert rules (thresholds, `group_by`, cooldown, renotify) |

### Zen builder

1. Open **Logs** tab → create or edit a Zen rule (`/settings/rules/zen/new` or
   `/settings/rules/zen/<id>`).
2. Start from a built-in template (passthrough, CEF severity, SNMP severity, …).
3. Set order; leave disabled while drafting; enable when validation looks good.

The visual editor supports canvas and raw JSON. See [Rule Builder](./rule-builder.md).

---

## 13. Threat intelligence and vulnerability feeds

### 13.1 Threat intel (AlienVault OTX)

**Where:** **Settings → Threat Intel** (`/settings/networks/threat-intel`)

This page configures **AlienVault OTX** collection and matching against recent
flows:

1. Enable OTX and store a **core OTX API key** where prompted.
2. Ensure an **approved AlienVault OTX** plugin package exists; assign the edge
   collector to an agent that can reach OTX (Wasm plugin assignment).
3. Queue **OTX sync** and confirm indicators appear in local inventory counts.
4. Optionally run **retrohunt** over retained telemetry when available.
5. Confirm NetFlow detail panels show threat-intel hits after the match cache
   evaluates imported IOCs against recent flows.

Generic CIDR feed toggles may also appear under **Network Flows** settings
alongside GeoIP—keep threat-intel credentials out of chat and git.

### 13.2 Vulnerability feeds (CISA KEV, VulnCheck, NVD CPE)

**Where:** **Settings → Vulnerability Feeds**  
(`/settings/security/vulnerability-feeds`)  
(UI title: **Vulnerability Intelligence**)

These feeds run **in core on a schedule**—no agent involvement:

| Feed | Credential |
| --- | --- |
| **CISA Known Exploited Vulnerabilities** | Not required |
| **VulnCheck KEV** | Required (API token via credential secret) |
| **VulnCheck nist-nvd2 (NVD CPE)** | Required |

For each feed you can enable/disable, set refresh cadence (hourly through weekly),
attach a credential secret where required, and **run now**.

Store API keys only in the Settings UI credential selectors.

---

## 14. Integrations: Armis, NetBox, Ansible

### Armis

**Where:** **Settings → Integrations** (`/settings/networks/integrations`)

Connect Armis as an inventory source, map credentials, and enable sync so Armis
assets enrich the device graph. See [Armis](./armis.md).

### NetBox

Same Integrations area—point at your NetBox API, set token and cadence, verify
devices/prefixes land in inventory. Prefix tags can also consume IPAM context.  
See [NetBox](./netbox.md), [Prefix Tags](./prefix-tags.md).

### Ansible / AWX

**Where:** **Settings → Ansible** (`/settings/ansible`)

Cloud pattern:

1. Deploy a ServiceRadar **agent** that can reach your private AWX/AAP.
2. Import and assign the **AWX Wasm plugin** to that agent  
   (**Settings → Plugins Manager**)—manual package lifecycle.
3. Register the AWX controller, purpose-scoped OAuth tokens, and playbook sources
   under **Settings → Ansible**.
4. Launch playbooks from ServiceRadar; watch run status and activity.

Core never needs direct reachability to AWX; the agent bridges the network.  
Full guide: [Ansible Integration](./ansible.md).

---

## 15. Telemetry onboarding (OTLP)

**Where:** **Settings → Telemetry Onboarding**  
(`/settings/agents/telemetry-onboarding`)

Use this page when applications should export OpenTelemetry to the hosted
collector:

1. Copy the environment’s OTLP gRPC/HTTP endpoints from the form.
2. Issue or paste the ingestion key material as documented on the page  
   (operator apply may still be required for secret-mounted collector config).
3. Use the provided snippets (collector, language SDKs).

The collector accepts OTLP over gRPC and HTTP (binary protobuf; OTLP/JSON is
rejected). See [OpenTelemetry](./otel.md).

---

## 16. First-week checklist

Progressive rollout beats enabling everything on day one.

| Day | Focus | Done when |
| --- | --- | --- |
| 1 | Network access publish; open product UI; enroll 1–2 agents | Agents **Online** |
| 2 | Pre-create users; draft SSO; assign RBAC | Non-admin SSO login works with correct role |
| 3 | Host Health profile + credential rules + SNMP **or** a small sweep | Metrics or inventory updates |
| 4 | Syslog **or** NetFlow from one device class | Events/flows visible |
| 5 | Review Zen defaults; enable one alert rule | Alert fires and notifies |
| 6 | Optional: Armis/NetBox, netprobe, OTX, vulnerability feeds | Integration/feed health green |
| 7 | Agent release canary practice; document listener hostnames | Ops note complete |

---

## 17. Day-2 operations

- **Agents:** canary first; treat digest/signature failures as release-pipeline
  problems until proven otherwise ([Agent Release Management](./agent-release-management.md)).
- **Wasm plugins:** schedule periodic version reviews; promote deliberately in
  **Plugins Manager**.
- **Native add-ons:** leave first-party packages on track-latest unless you need a
  pin; investigate health-gated rollbacks if a batch fails ([Native Add-ons](./native-addons.md)).
- **Credentials:** rotate via credential rules; keep the `admin` set small.
- **Network access:** re-publish after egress IP changes; keep UDP collectors tight.
- **Capacity:** use control-plane billing/add-ons when ingress or storage approaches
  plan limits.
- **Troubleshooting:** [Troubleshooting Guide](./troubleshooting-guide.md). Prefer
  product UI health surfaces and control-plane support on Cloud over self-hosted
  “tools pod” workflows.

---

## 18. Related docs

| Topic | Doc |
| --- | --- |
| Self-hosted install | [Quickstart](./quickstart.md), [Docker](./docker-setup.md), [Helm](./helm-configuration.md) |
| Architecture | [Architecture](./architecture.md), [Edge model](./edge-model.md) |
| Agents | [Edge onboarding](./edge-agent-onboarding.md), [Agent config](./agent-configuration.md), [Releases](./agent-release-management.md) |
| Auth / RBAC | [Authentication](./auth-configuration.md), [Roles](./rbac-and-roles.md) |
| Data plane | [Syslog](./syslog.md), [SNMP](./snmp.md), [NetFlow](./netflow.md), [BGP/BMP](./bgp-routing.md), [OTEL](./otel.md) |
| Automation | [Ansible](./ansible.md), [Rule builder](./rule-builder.md) |
| Extensions | [Wasm plugins](./wasm-plugins.md), [Native add-ons](./native-addons.md) |
| Query | [SRQL tutorial](./srql-tutorial.md), [SRQL cookbook](./srql-cookbook.md) |

---

## Support

For hosted provisioning, network access verification, or platform incidents:

1. Use the control-plane support path for your tenant at
   [control.serviceradar.cloud](https://control.serviceradar.cloud), or  
2. Email `support@serviceradar.cloud`.

Include: tenant/workspace slug, approximate timestamps (UTC), environment region,
and whether the issue is **agent connectivity**, **collector ingest**,
**auth/SSO**, or **UI/product**.
