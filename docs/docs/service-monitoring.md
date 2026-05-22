---
id: service-monitoring
title: Service Monitoring
sidebar_label: Service Monitoring
description: Configure device and service checks, credentials, events, alerts, SLOs, and NOC dashboards.
---

# Service Monitoring

Service monitoring lets operators run loaded plugin and built-in checks against
inventory devices and first-class service targets. A service target can be tied
to a device, hosted by a group of devices, or standalone, such as a public URL
or external database endpoint.

Use service monitoring when the operator intent is "monitor this device or
service with this available capability" instead of "edit a plugin-specific
target list." This keeps large configurations, such as 200 URLs or 200
databases, in inventory and policy records that can be searched, audited, and
queried with SRQL.

## Core objects

| Object | Purpose |
| --- | --- |
| Monitored service | Durable target such as an HTTPS URL, TCP endpoint, TLS endpoint, database, DNS name, or custom service. |
| Service group | Explicit, tag-backed, import-backed, or SRQL-backed collection of services. |
| Check descriptor | Plugin or built-in capability such as `http.url.availability`, `postgres.availability`, `tcp.connect`, or `tls.certificate_expiry`. |
| Monitoring binding | Policy that binds one descriptor to a target set, schedule, vantage point, credential strategy, threshold policy, event policy, and alert policy. |
| Check instance | Materialized runtime identity for one descriptor, target, and vantage point. |
| SLI | Reliability measurement such as availability, success ratio, latency, freshness, or an approved SRQL ratio. |
| SLO | Objective over an SLI, target set, goal, compliance period, burn-rate policy, owner, and alert policy. |

Devices remain the asset inventory. Services are monitored endpoints. Link a
service to a device when that relationship is useful, for example a PostgreSQL
listener on a database host or many virtual hosts served by one web server.
Leave the service standalone when it represents an external website or SaaS
endpoint that should not become a fake device.

## Permissions and audit

Service monitoring follows the existing RBAC catalog:

- View service monitoring records: `services.view`.
- Create service targets, groups, bindings, SLIs, and SLOs: `services.create`.
- Update, activate, disable, retire, or archive them: `services.update`.
- Reconcile bindings and record runtime evaluation state: `services.run`.

Configuration resources use Ash state machines and AshPaperTrail version
tables. Status transitions, credential policy changes, target-set changes, SLO
goal changes, and bulk import lifecycle updates are auditable.

## Import 200 URLs

For large URL estates, use a bulk import or API path rather than editing plugin
configuration. A URL import should normalize each row into a monitored service
with:

- `service_kind`: `http`
- `protocol`: `https` or `http`
- `endpoint_url`: full URL to check
- `host`, `port`, and `path`: parsed from the URL
- tags such as `role=public-web`, `noc=primary`, or `app=<name>`

Then create a service group and bind the loaded HTTP capability to that group:

```text
descriptor: http.url.availability
target set: service group "Public Websites"
interval: 60 seconds
timeout: 5 seconds
credential policy: none, optional, or brokered HTTP auth
event policy: emit status changes and selected warning states
alert policy: promote repeated critical states with cooldown
```

Useful SRQL checks after import:

```srql
in:monitored_services service_kind:http tag.role:public-web sort:display_name:asc limit:25
```

```srql
in:service_availability service_kind:http status:critical time:last_1h sort:last_observed_at:desc
```

```srql
in:service_availability service_kind:http rollup_stats:availability
```

## Import 200 databases

Database targets follow the same model, but credentials should be brokered. A
database import should normalize each row into a monitored service with:

- `service_kind`: `database`
- `protocol`: `postgres`, `mysql`, `mssql`, or another supported descriptor protocol
- `host`, `port`, and optional `database_name`
- tags such as `role=database`, `environment=prod`, or `noc=primary`
- optional `device_uid` when the service is hosted by a known inventory device

The binding should require a credential purpose such as `database.monitor`.
Credential selection is evaluated in this order:

1. Per-service override for the same provider and purpose.
2. Per-device override when the service is associated with a device.
3. Enabled network-wide credential rules matching the device, service, and edge scope.
4. Binding-level credential requirement: `none`, `optional`, or `required`.

Credential sources can be internally encrypted ServiceRadar secrets or external
secret-provider references. The compiler sends broker grants and credential
source references to trusted runtime code. Plugins do not receive plaintext
passwords, API keys, private keys, cookies, or tokens.

Useful SRQL checks:

```srql
in:monitored_services service_kind:database tag.role:database sort:display_name:asc limit:25
```

```srql
in:service_availability descriptor_id:postgres.availability status:(critical,unknown) time:last_24h
```

## Device-tag-driven monitoring

When a check applies to devices, select the devices by inventory tags or SRQL
instead of typing device identifiers. Examples:

```srql
in:devices tag.role:database tag.environment:prod
```

```srql
in:devices tag.site:dc1 status:active
```

A device-scoped binding can create one check instance per matched device, or a
service template can create a database/TCP/TLS monitored service for each
matched device. The target preview should show count, included devices,
excluded devices, and the reason each excluded device is not eligible.

## Events and alerts

Monitoring bindings control what check results do:

- update latest check state and service availability rollups
- emit informational, warning, or critical OCSF events on configured transitions
- pass matching events into the stateful alert engine
- dedupe, group, cool down, and re-notify using existing observability rules

Use informational events for state changes that operators should be able to
audit or search, even when they do not need an alert. Promote only actionable
conditions to alerts, such as repeated critical checks, missing required
credentials, budget exhaustion, or critical SLO burn rate.

## SLI and SLO workflow

Create SLIs from normalized check state or approved SRQL templates. Common
starting points:

- Availability SLI: good statuses are `ok` and optionally `warning`.
- Success-ratio SLI: good events divided by eligible check events.
- Latency SLI: checks whose latency metric is below a threshold.
- Freshness SLI: checks observed within an expected interval.

Create SLOs against service groups, service tags, explicit services, device
selectors, or service SRQL. Goals are stored in basis points, so `9990` means
99.90%. A goal of 100% is rejected because it leaves no error budget.

Compliance periods can be rolling or calendar based:

- Rolling periods evaluate the last 1 to 30 days.
- Calendar periods evaluate day, week, month, or quarter boundaries.
- Request-based SLOs compare good events to eligible events.
- Window-based SLOs compare good windows to total windows.

Useful SRQL for SLO review:

```srql
in:slos status:active owner:noc
```

```srql
in:slo_evaluations compliance_state:(at_risk,noncompliant) sort:evaluated_at:desc limit:20
```

ServiceRadar records error-budget remaining, short and long burn rates,
projected exhaustion time, compliance state, event IDs, and alert IDs on SLO
evaluations. SLO transitions emit OCSF events and can promote to alerts through
the same alert engine used by check events.

## NOC dashboard queries

First-party service availability and SLO dashboards should be authored as
dashboard SDK packages. The dashboard should be SRQL-driven and filter by tags,
service group, descriptor, agent or vantage point, status, severity, and owner.

High-signal frames:

```srql
in:service_availability tag.noc:primary rollup_stats:availability
```

```srql
in:service_availability tag.noc:primary status:(critical,unknown) sort:last_observed_at:desc limit:50
```

```srql
in:monitored_services tag.noc:primary sort:display_name:asc limit:200
```

```srql
in:slo_evaluations severity:(warning,critical) sort:evaluated_at:desc limit:25
```

## Demo seed

After applying the service monitoring migrations, seed a demo or staging
database with:

```bash
psql "$DATABASE_URL" -f docs/static/examples/service-monitoring-demo-seed.sql
```

The seed creates:

- 200 synthetic HTTPS URL services.
- 200 synthetic PostgreSQL services.
- Service groups for URLs, databases, and NOC-critical services.
- Monitoring bindings for HTTP and PostgreSQL availability descriptors.
- Check instances and latest check state with a mix of OK, warning, and critical states.
- Availability SLIs, SLOs, and example SLO evaluations with budget and burn-rate state.

The database targets are marked with `credential_purpose=database.monitor` and
`credential_demo=openbao-ready` metadata so they can be used to validate an
external secret-provider broker without granting plugins direct credential
access.
