---
title: SRQL Cookbook
---

# SRQL Cookbook

Task-oriented, copy-paste SRQL recipes. Each recipe has a goal, a query you can run
as-is, and a one-line note. Adjust hostnames, IPs, and time windows to match your
environment.

New to the language? Read the [SRQL Tutorial](./srql-tutorial.md) first. For the
full list of entities, fields, and operators, see the
[SRQL Reference](./srql-language-reference.md).

---

## Finding and inspecting devices

### List recently seen devices

```srql
in:devices sort:last_seen:desc limit:25
```

The 25 devices that checked in most recently.

### List newly added devices

```srql
in:devices first_seen:last_30d sort:first_seen:desc limit:200
```

Devices first discovered in the last 30 days. `time:last_30d` still means
last seen, not first seen.

### Find a device by hostname

```srql
in:devices hostname:%edge%
```

Wildcard match — every device whose hostname contains `edge`.

### Find a device by IP, CIDR, or range

```srql
in:devices ip:10.20.0.0/16
```

`ip:` accepts a single address, a CIDR block, or a range like
`10.20.0.10-10.20.0.50`.

### List devices from one vendor

```srql
in:devices vendor_name:Cisco sort:hostname:asc
```

Use quotes for multi-word vendors: `vendor_name:"Axis Communications"`.

### Find unreachable devices

```srql
in:devices is_available:false sort:last_seen:desc
```

Devices currently marked unavailable, newest first.

### Devices discovered by a specific source

```srql
in:devices discovery_sources:(armis)
```

`discovery_sources` is an array field; the list form matches containment.

### Devices with a CVE or KEV match

```srql
in:devices cve:CVE-2024-1234
in:devices kev:true
```

Device grain: one row per host that has an **active** matcher hit. There is
no `in:devices cpe:`; use `in:endpoint_packages` for installed CPEs. See
[Threat Investigation](./threat-investigation.md).

### Devices imported by an Armis integration query

```srql
in:devices metadata.integration_type:armis metadata.query_label:managed
```

`metadata.<key>` filters arbitrary metadata; quote values with spaces.

### Count devices by type

```srql
in:devices stats:count() as total by type
```

A breakdown of inventory by device type.

### Count devices by vendor

```srql
in:devices stats:count() as total by vendor_name sort:total:desc
```

The most common vendors in your fleet.

### Count composite-check verdicts

```srql
in:composite_results stats:count() as n by check,verdict
```

A GROUP BY, not a truncated row dump. Unsupported aggregations or group
fields return `InvalidRequest` instead of silently listing rows.

### Roll up composite-check vantage inputs

```srql
in:composite_results check:pci-isolation stats:"count() as n by input_key, input_value, input_stale"
```

Unnests the `inputs` JSONB map. Empty or null `inputs` contribute no
vantage rows.

---

## Inspecting events and logs

### Recent events, newest first

```srql
in:events time:last_24h sort:time:desc limit:50
```

A live feed of the latest events.

### High-severity events only

```srql
in:events time:last_24h severity_id:>3 sort:time:desc
```

Filters out low-severity noise.

### Events for a specific device

```srql
in:events device_id:<device-uid> time:last_7d sort:time:desc
```

Everything that happened on one device this week.

### Search event messages

```srql
in:events message:%authentication% time:last_24h
```

Free-text search inside event messages with a wildcard.

### Error logs from one service

```srql
in:logs service_name:serviceradar-core severity_text:error time:last_1h
```

Recent error-level lines from a single service.

### Logs across several severities

```srql
in:logs severity_text:(error,warn) time:last_6h sort:timestamp:desc
```

The list form matches any of the listed severities.

### Search log bodies

```srql
in:logs body:%timeout% time:last_24h
```

Find log lines mentioning `timeout`.

### Correlate logs by trace ID

```srql
in:logs trace_id:<trace-id> sort:timestamp:asc
```

All log lines for one distributed trace, in order.

### Count log volume by severity

```srql
in:logs time:last_24h stats:count() as total by severity_text
```

How much of each severity you are producing.

---

## Threat intel investigation

Current IP/CIDR matches are cache memberships, not flow hits. The investigation
UI is `/security/threat-intel`. Feed configuration stays at
**Settings → Networks → Threat Intel**.

### List current OTX matches

```srql
in:threat_intel_matches source:alienvault_otx sort:evaluated_at:desc limit:100
```

One row per endpoint-to-indicator membership. `evaluated_at` is when the cache
was last evaluated.

### Flows that currently match threat intel

```srql
in:flows threat_matched:true time:last_24h sort:time:desc limit:100
```

Each flow appears once even if several indicators cover an endpoint. Omitting
`time:` defaults to the last 24 hours.

### Flows for one indicator CIDR

```srql
in:flows threat_indicator:"198.51.100.0/24" time:last_24h sort:time:desc limit:100
```

### Attributed threat-matched flows

```srql
in:attributed_flows threat_source:alienvault_otx time:last_24h sort:time:desc limit:100
```

## NetFlow traffic queries

### Top talkers by bytes

```srql
in:flows time:last_1h stats:sum(bytes_total) as bytes by src_ip sort:bytes:desc limit:10
```

The 10 source IPs that sent the most traffic.

### All traffic for one host (both directions)

```srql
in:flows ip:8.8.8.8 time:last_24h sort:bytes_total:desc
```

`ip:` matches **either** endpoint, so this is everything the host sent *and*
received. `src_ip:` / `dst_ip:` are the directional forms. There is no cross-field
`OR` in SRQL; without `ip:` you would need two separate queries (or invent invalid
`(src_ip:… OR dst_ip:…)` syntax).

Same idea for a whole block — `cidr:` matches either endpoint, `src_cidr:` /
`dst_cidr:` are directional. For **ports**, use `port:` the same way (`port:22`
instead of directional `src_port` / `dst_port` only):

```srql
in:flows cidr:203.0.113.0/24 time:last_24h stats:sum(bytes_total) as bytes by app
```

### Traffic to a specific destination

```srql
in:flows dst_ip:8.8.8.8 time:last_24h sort:bytes_total:desc
```

All flows headed to one destination address. Note the address is written bare —
wrapping it in `%` turns the filter into a wildcard match, which is slower and
matches more than you asked for (`%10.0.0.1%` also matches `110.0.0.1`).

### Traffic matching part of an address

```srql
in:flows dst_ip:%34.98.126.% time:last_24h sort:bytes_total:desc
```

`src_ip` / `dst_ip` accept `%` wildcards for partial-address matching. Prefer
`src_cidr` / `dst_cidr` when you can express the range as a CIDR block — those
use real network containment and hit the address indexes.

### Large flows above a threshold

```srql
in:flows bytes_total:>10000000 time:last_1h sort:bytes_total:desc
```

Flows that moved more than 10 MB.

### Traffic on a specific port (one direction)

```srql
in:flows dst_port:(443,8443) time:last_1h
```

Destination is 443 or 8443. The list form is OR **on one field** only.

### Traffic on a port either direction (SSH, DNS, …)

```srql
in:flows time:last_24h port:22 sort:time:desc limit:50
```

`port:` (alias `endpoint_port:`) matches **either** endpoint port — the right
answer for “show me SSH” when netflow direction flips between client→server and
server→client. Directional forms remain `src_port:` / `dst_port:`.

```srql
in:flows time:last_24h port:(22,2222) sort:time:desc limit:50
```

List form works with `port:` as well (either side is 22 **or** 2222).

> **Do not write** `(dst_port:22 OR src_port:22)`. SRQL has no cross-field `OR`
> keyword; that parenthesized form tokenizes incorrectly and yields empty or
> invalid queries. Prefer `port:22` (or two separate queries). Full boolean
> groups are tracked in
> [issue #3557](https://github.com/carverauto/serviceradar/issues/3557).

### Traffic from a subnet

```srql
in:flows src_cidr:10.0.0.0/8 time:last_1h sort:bytes_total:desc
```

`src_cidr` / `dst_cidr` match flows inside a CIDR block.

### Prefix tags (site / role / tenant)

```
in:flows tag:site:austin time:last_1h
```

```
in:flows dst_tag:role:guest-wifi time:last_1h sort:bytes_total:desc
```

```
in:flows tag:tenant:acme src_cidr:10.0.0.0/8 time:last_6h
```

`tag:` matches either side; `src_tag:` / `dst_tag:` are directional. Tags come from
IPAM prefix enrichment (see [Prefix Tags](./prefix-tags.md)).

### Proximity (geo cache)

```
in:flows near:30.2672,-97.7431,50km time:last_6h
```

```
in:flows tag:ti:otx near:30.27,-97.74,50km time:last_24h
```

```
in:flows dst_near:37.7749,-122.4194,25mi time:last_1h
```

`near:` matches if **either** endpoint's IP is within the radius of the coordinate
according to `platform.ip_geo_enrichment_cache` (PostGIS `ST_DWithin` on the
generated `location` geography). `src_near:` / `dst_near:` are directional.
Radius units: `km` (default if omitted), `m`, `mi`. IPs missing from the geo
cache are excluded from proximity matches without error.

### Traffic broken down by application

```srql
in:flows time:last_1h stats:sum(bytes_total) as bytes by app sort:bytes:desc
```

`app` is the derived application classification label.

### Flow volume over time (chart)

```srql
in:flows time:last_6h bucket:5m agg:sum value_field:bytes_total
```

Five-minute buckets suitable for a time-series chart.

> **UI note:** On the NetFlow **Traffic Analysis** overview, summary cards
> (Total Flows, TCP/UDP, bytes) honor `port:` and `ip:` filters. The stacked
> **Ports** series chart may still show “No ports samples” for some filtered
> queries while the cards are non-zero — open **Flow Explorer** for the raw
> row table, or switch SERIES to **Talkers**.

---

## Attributed flows and public endpoints

Attributed flows are NetFlow rows joined with host process context (netprobe)
and, when the 5-tuple hits a known public VIP, Kubernetes ownership from
`public_endpoints`. Use `in:attributed_flows` when you care about process,
pod, or Gateway/Service owner — not only the 5-tuple.

### Inventory: who owns this public VIP / port?

```srql
in:public_endpoints port:22 limit:50
```

```srql
in:public_endpoints ip:198.51.100.10
```

```srql
in:public_endpoints exposure_class:Gateway sort:ip:asc limit:50
```

Current snapshot of LoadBalancer / Gateway exposures (no `time:` required).

### All attributed traffic involving a public VIP

```srql
in:attributed_flows time:last_24h ip:198.51.100.10 sort:time:desc limit:50
```

Same bidirectional `ip:` helper as raw flows. In the UI, rows show **PROCESS**
(e.g. `nginx`, `anubis`) and **PUBLIC ENDPOINT** (e.g. `Gateway: serviceradar-web`)
when the correlator stamped ownership.

### Filter by public endpoint owner

```srql
in:attributed_flows time:last_24h service_name:serviceradar-web sort:time:desc limit:50
```

```srql
in:attributed_flows time:last_24h service_name:harbor-http sort:time:desc limit:50
```

```srql
in:attributed_flows time:last_24h exposure_class:Gateway sort:time:desc limit:50
```

`service_name:` / `exposure_class:` / `gateway_name:` / `route_name:` filter
`attribution.public_endpoint` fields — only present after VIP join.

### SSH: raw vs attributed

```srql
in:flows time:last_24h port:22 sort:time:desc limit:50
```

Raw SSH 5-tuples (works even without process join). Summary cards should match
DB counts.

```srql
in:attributed_flows time:last_24h port:22 sort:time:desc limit:50
```

Only rows that also have host process attribution on port 22. This can be
**empty** while `in:flows port:22` is busy — that means netflow saw SSH but
netprobe did not join a process (or no SSH hit a joined socket yet), not that
`port:` is broken.

```srql
in:attributed_flows time:last_24h service_name:git-ssh sort:time:desc limit:50
```

SSH that was stamped with the public endpoint owner `git-ssh`. Requires
inventory + correlator VIP join on `:22`.

### Process-focused attributed traffic

```srql
in:attributed_flows time:last_1h process:sshd sort:time:desc limit:50
```

```srql
in:attributed_flows time:last_1h process:anubis attribution_status:attributed
```

### When PUBLIC ENDPOINT is blank

A blank public endpoint on an attributed row is expected when **neither** side
of the 5-tuple is a catalogued VIP:port (for example node IP + ephemeral port
talking to the internet). Process join can still succeed (`rspamd` on a
worker). Ownership of a public listener is a different question from “did a
host process touch this socket?”

---

## BGP routing queries

BGP routing data is queried with `in:bmp_events` — peer events and prefix
advertisements collected via the BGP Monitoring Protocol.

### Recent BGP routing events

```srql
in:bmp_events time:last_24h sort:time:desc limit:50
```

The latest BMP events across all routers.

### Events from one router

```srql
in:bmp_events router_ip:10.42.68.85 time:last_24h sort:time:desc
```

All routing activity reported by a single router.

### Events for a specific BGP peer

```srql
in:bmp_events peer_ip:10.42.68.1 time:last_7d
```

Track one peering session.

### Events for a peer ASN

```srql
in:bmp_events peer_asn:64512 time:last_24h
```

`peer_asn` and `local_asn` are numeric fields.

### Track a specific prefix

```srql
in:bmp_events prefix:%203.0.113.0% time:last_7d sort:time:desc
```

Advertisements and withdrawals touching a prefix.

---

## Building queries for alert rules

Alert rules run an SRQL query on a schedule and fire when results cross a threshold.
Keep rule queries tightly scoped: an explicit entity, a `time:` window, and a
condition.

### Devices that went offline

```srql
in:devices is_available:false time:last_15m
```

Any result rows mean devices are down.

### Sustained high CPU

```srql
in:cpu_metrics time:last_15m usage_percent:>90 sort:usage_percent:desc
```

Hosts running hot in the recent window.

### Disks nearly full

```srql
in:disk_metrics time:last_30m usage_percent:>85 sort:usage_percent:desc
```

Mount points approaching capacity.

### High memory pressure

```srql
in:memory_metrics time:last_15m usage_percent:>90
```

Hosts with little free memory.

### Spike in error logs

```srql
in:logs severity_text:error time:last_5m stats:count() as errors
```

Compare the `errors` count against your alert threshold.

### Burst of high-severity events

```srql
in:events severity_id:>3 time:last_5m stats:count() as critical_events
```

Alert when `critical_events` exceeds a baseline.

### Service availability check

```srql
in:services available:false time:last_10m
```

Services reporting as unavailable.

---

## Common troubleshooting queries

### Is a device reporting at all?

```srql
in:devices hostname:%<name>% sort:last_seen:desc
```

Check `last_seen` to see when the device last checked in.

### What changed on a device recently?

```srql
in:events device_id:<device-uid> time:last_1h sort:time:desc
```

Recent activity on a suspect device.

### Find slow service spans

```srql
in:otel_metrics is_slow:true time:last_1h sort:timestamp:desc
```

Span-derived metrics flagged as slow.

### Inspect a failing trace

```srql
in:traces status_code:2 time:last_1h sort:timestamp:desc
```

Trace spans with an error status code.

### Check interface status on a device

```srql
in:interfaces device_ip:10.0.0.5 latest:true
```

`latest:true` returns the most recent record per interface.

### Find down interfaces

```srql
in:interfaces oper_status:down latest:true
```

Interfaces currently in a down operational state.

### Verify gateway health

```srql
in:gateways is_healthy:false
```

Gateways that are not reporting healthy.

### Recent SNMP metric values for a device

```srql
in:snmp_metrics device_id:<device-uid> time:last_1h sort:timestamp:desc
```

Confirm SNMP polling is producing data.

### Check unresolved alerts

```srql
in:alerts status:open sort:triggered_at:desc
```

Open alerts, most recently triggered first.

---

## Threat investigation

Fleet queries for CVE, CPE, KEV, and matcher exposure. Full walkthrough:
[Threat Investigation](./threat-investigation.md).

### Look up a CVE in the catalog

```srql
in:cves cve:CVE-2024-1234
```

NVD/KEV advisory metadata. Default `current:true`. Not "is this on our
fleet."

### List KEV advisories by CVSS

```srql
in:advisories kev:true cvss_score:>=9.0 sort:cvss_score:desc
```

### List CPE applicability for a CVE

```srql
in:advisory_cpes cve:CVE-2024-1234 coordinate_type:cpe
```

Catalog coordinates with version bounds. SRQL does not evaluate whether an
installed version is in range.

### Hosts currently running a CPE

```srql
in:endpoint_packages cpe:cpe:2.3:a:nginx:nginx:% current:true
```

Array overlap on installed package CPEs. Each row has `device_uid`.

### Packages and devices with actionable assessments

```srql
in:cve_matches status:active assessment:confirmed disposition:affected kev:true sort:cvss_score:desc
in:cve_matches cve:CVE-2024-1234
in:cve_matches stats:count() as audit_rows
in:cve_matches status:active assessment:confirmed disposition:affected stats:count() as exposed
in:endpoint_packages cve:CVE-2024-1234 current:true
```

Unqualified row browsing includes confirmed, candidate, and resolved states;
there is no implicit active-only filter. Likewise, an unqualified
`stats:count()` is a count of persisted audit/state rows, not current exposure.
Use the exact `status:active assessment:confirmed disposition:affected` triple
for actionable exposure rows or counts. `in:security_findings cve:` is the OCSF
occurrence stream, not this table. Do not use `in:cpes` as an entity.

---

## See also

- [SRQL Tutorial](./srql-tutorial.md) — guided, beginner-friendly introduction.
- [SRQL Reference](./srql-language-reference.md) — complete grammar, entities, and
  fields.
- [Threat Investigation](./threat-investigation.md) — CVE, CPE, KEV, and matcher
  queries.
