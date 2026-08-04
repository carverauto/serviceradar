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
`OR` in SRQL, so without `ip:` this question needs two separate queries.

Same idea for a whole block — `cidr:` matches either endpoint, `src_cidr:` /
`dst_cidr:` are directional:

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

### Traffic on a specific port

```srql
in:flows dst_port:(443,8443) time:last_1h
```

HTTPS-style traffic; the list form matches either port.

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

## See also

- [SRQL Tutorial](./srql-tutorial.md) — guided, beginner-friendly introduction.
- [SRQL Reference](./srql-language-reference.md) — complete grammar, entities, and
  fields.
