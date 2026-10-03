---
title: SRQL Reference
---

# SRQL Reference

**SRQL** (ServiceRadar Query Language) is a compact `key:value` language for
querying devices, events, logs, flows, and telemetry. This page is the complete
reference: grammar, queryable entities, filterable fields, operators, time syntax,
and aggregation.

New to SRQL? Start with the [SRQL Tutorial](./srql-tutorial.md) for a guided
walkthrough, or jump to the [SRQL Cookbook](./srql-cookbook.md) for ready-made
recipes.

## Overview

The Rust-based SRQL engine (`rust/srql`) parses the `key:value` syntax into a
query AST and validates the query plan. Web-ng executes SQL plans against the
configured backend and returns consistently shaped results. Agent extension
fleet plans use the scoped read models described in
[Agent extension fleet queries](#agent-extension-fleet-queries).

Use SRQL to:

- Select a data domain with `in:<entity>`.
- Filter with `key:value` pairs, wildcards, lists, ranges, and negation.
- Scope to a time window with `time:`.
- Shape results with `sort:`, `limit:`, and pagination cursors.
- Summarize with `stats:` aggregations or `bucket:` downsampling.

## Query structure

A query is a whitespace-separated list of tokens. Every token is either the `in:`
selector, a reserved keyword (`time`, `sort`, `limit`, `stats`, etc.), or a
`key:value` filter. Tokens may appear in any order, but every query **must** include
exactly one `in:` selector.

```
in:<entity> [key:value ...] [time:<window>] [sort:<field>[:dir]] [limit:<n>] [stats:<expr>]
```

Example:

```srql
in:devices vendor_name:Cisco hostname:%core% time:last_7d sort:last_seen:desc limit:20
```

### Tokenization rules

- Tokens are separated by whitespace.
- Wrap values containing spaces in quotes: `vendor_name:"Axis Communications"`.
  Single quotes, double quotes, and backticks are all accepted.
- Parentheses `( )` and brackets `[ ]` group list and range values; whitespace
  inside them does not split the token.
- Keys are case-insensitive and lowercased before matching.

## The `in:` selector

`in:<entity>` chooses which data domain to query. The entity name is
case-insensitive, and most entities accept several aliases (for example
`in:devices` and `in:device` are equivalent).

See [Queryable entities](#queryable-entities) for the full list of entities,
aliases, and fields.

## Operators

SRQL infers the operator from the value you write.

| Form | Operator | SQL behavior |
|------|----------|--------------|
| `field:value` | equals | `=` |
| `!field:value` | not equals | `<>` |
| `field:%text%` | contains | `ILIKE` (case-insensitive) |
| `!field:%text%` | does not contain | `NOT ILIKE` |
| `field:(a,b,c)` | one of | `IN (...)` |
| `!field:(a,b,c)` | none of | `NOT IN (...)` |
| `field:>n` | greater than | `>` |
| `field:>=n` | greater than or equal | `>=` |
| `field:<n` | less than | `<` |
| `field:<=n` | less than or equal | `<=` |

Notes:

- **Negation** applies to the *key*, written as `!key:value`. Writing `key:!value`
  is not supported.
- **AND** is implicit: listing multiple filters means all of them must match.
- **OR** for a single field is the list form `field:(a,b)`. There is no general
  `OR` keyword across different fields — parenthesized expressions such as
  `(dst_port:22 OR src_port:22)` are **not** valid SRQL (they tokenize as a
  single broken `key:value`). Cross-field “either side” cases use dedicated
  bidirectional fields instead (see below). Tracking for full boolean groups:
  [issue #3557](https://github.com/carverauto/serviceradar/issues/3557).
- **Bidirectional flow helpers** (flows / attributed_flows):
  - `ip:` / `endpoint_ip:` — either endpoint IP
  - `port:` / `endpoint_port:` — either endpoint port
  - `cidr:` — either endpoint in a CIDR
  - Prefer these over inventing `(src_* OR dst_*)` syntax
- **Ranges** are expressed by repeating a numeric field with two comparison bounds:
  `usage_percent:>80 usage_percent:<95`.
- List filters accept at most 200 values.

## Wildcards

`%` is the wildcard character for string matching. It matches any run of characters
and emits a case-insensitive `ILIKE` (or `NOT ILIKE` when negated).

```srql
in:devices hostname:router-%      # starts with "router-"
in:devices hostname:%.lab          # ends with ".lab"
in:devices hostname:%core%         # contains "core"
```

A value with no `%` is matched for exact equality.

## Time scoping

Use `time:` (alias `timeFrame:`) to constrain time-series queries. If you omit a
time window, the engine applies a default window.

### Relative windows

`time:last_<number><unit>` — units are `m` (minutes), `h` (hours), `d` (days), and
`y` (years).

```srql
in:events time:last_30m
in:logs time:last_24h
in:flows time:last_7d
```

### Shortcuts

```srql
in:events time:today
in:events time:yesterday
```

### Absolute ranges

Bracket syntax `[start,end]` accepts RFC 3339 timestamps. Leave a side blank for an
open-ended range.

```srql
in:events time:[2026-01-01T00:00:00Z,2026-01-02T00:00:00Z]
in:events time:[2026-01-01T00:00:00Z,]      # open end
in:events time:[,2026-01-02T00:00:00Z]      # open start
```

### Limits

Most queries are capped at a 90-day time range. Aggregated metric queries (a metric
entity combined with `stats:` or `bucket:`) may span a longer window. Hourly rollups
serve the aggregates that have a stored column. `agg:last` does not use them; see
[Downsampling with `bucket`](#downsampling-with-bucket).

## Sorting and pagination

- `sort:<field>[:asc|:desc]` — orders results. Direction defaults to `desc`.
  Multiple sort keys are comma-separated: `sort:time:desc,bytes_total`.
  `order:` is an accepted alias for `sort:`.
- Device queries support `sort:hostname:asc` and `sort:hostname:desc`,
  including hostname as a secondary sort key. UID ascending is the final
  tie-breaker. Null hostnames appear last in ascending order and first
  in descending order; empty hostnames remain empty strings.
- `limit:<n>` — caps the number of rows returned in one page. Must be a
  positive integer. An explicit limit is the limit that runs. When
  `srql_max_limit` is set above zero, that configured maximum still applies.
  Grouped device stats default to 20 groups when `limit:` is omitted. A page
  that comes back full includes `next_cursor`, which means further rows or
  groups may exist.
- On `bucket:` queries `sort:` selects which end of the time window survives
  `limit:`, not the order rows come back in. See
  [Downsampling with `bucket`](#downsampling-with-bucket).
- Pagination is cursor-based. Each response includes `next_cursor` / `prev_cursor`
  values that callers pass back to page through results.
- The configured cursor-offset cap applies to ordinary queries. Seasonal
  `stats:profile_hour_of_week(value)` and `stats:profile_hour_of_week_full(value)`
  queries are exempt so cohort discovery and baseline delivery can page to
  completion. A query may also set `window_scan:true` to take the same
  exemption. Maintenance jobs that have to cover a time window use it.
  Interactive queries omit it and still receive the cursor-limit error past
  the ceiling. This exception applies to both query execution and SQL
  translation, including caller-supplied queries; it is not restricted to
  internal workers. Per-page row limits still apply.

## Aggregation with `stats`

`stats:` collapses rows into summary values.

```
stats:<function>(<field>) as <alias> [by <field>]
```

- Functions: `count`, `sum`, `avg`, `min`, `max`.
- `count()` takes no field; the others require one.
- `as <alias>` names the result column.
- `by <field>` groups results (the SQL `GROUP BY`).
- Combine multiple aggregations with commas:
  `stats:"count() as total, avg(value) as average"`.

```srql
in:devices stats:count() as total by type
in:timeseries_metrics metric_type:"sysmon.cpu" metric_name:"cpu.usage_percent" time:last_24h stats:avg(value) as avg_cpu by metric_name
in:flows time:last_1h stats:sum(bytes_total) as bytes by src_ip sort:bytes:desc
```

Legacy `in:cpu`, `in:memory`, `in:disk`, and `in:processes`
(with canonical names `cpu_metrics`, `memory_metrics`, `disk_metrics`, and
`process_metrics`) remain supported. They project the corresponding
`sysmon.*` samples in `timeseries_metrics` into legacy row fields on both CNPG
and StarRocks through Readers. Saved filters, stats, sorting, and downsampling
keep working.

Historical aggregates use existing timeseries hourly rollups when those rollups
preserve the requested fields, filters and series. The general rollup retains
device identity and metric values; CNPG's disk rollup also retains mount points.
Charts use hourly rollups only for buckets that are positive multiples of one
hour. Sub-hour and nonintegral-hour buckets use retained raw samples at the
requested resolution. Rollup-compatible aggregates include the full hours
containing the start and end timestamps, with the same effective window when
a stale warehouse rollup triggers a raw retry. Averages are weighted by sample
count. Shapes that require byte tags, host identity, process
names or other unretained dimensions read only the configured raw retention
(seven days by default on CNPG). StarRocks mount-specific queries also use raw
retention because its general hourly rollup does not retain mounts. This
compatibility does not restore expired samples or guarantee full historical
equivalence, and it never reads the retired dedicated sysmon tables.

New metric envelopes persist `resource.host_id` as `tags.host_id`, which supplies
legacy host fields, filters, series and sorting on both backends. Previously
stored samples without that tag do not acquire host identity retroactively.

### Composite-result stats

`in:composite_results` now honours `stats:`. The previous ignore dumped
matching rows, so a query that looked like a rollup still hit the
2,000-row frame ceiling. Unsupported aggregations and group fields
return `InvalidRequest` instead of that silent dump.

Only `count()` is supported. Group fields: `check` (aliases
`check_slug`, `slug`), `check_name`, `verdict`, `status`, `input_key`,
`input_value`, `input_stale`. `input_*` fields unnest the `inputs`
JSONB map with `jsonb_each` so a vantage rollup is a GROUP BY, not a
client fold. Default limit 100 when `limit:` is omitted. An explicit
`limit:` is honored. A full page sets `next_cursor`. Unquoted stats tokens
cannot contain spaces; write `by check,verdict` or quote the
expression.

```srql
in:composite_results stats:count() as n by check,verdict
in:composite_results check:pci-isolation stats:count() as n by verdict
in:composite_results check:pci-isolation stats:"count() as n by input_key, input_value, input_stale"
```

Do not group on `hostname`. Hostname is a second `in:devices uid:(…)`
frame scoped to the current page of result uids.

### Grouping devices by a tag or metadata key

`in:devices` can group on a JSONB sub-key as well as a column, which is how you
chart a dimension that only exists as a tag:

```srql
in:devices stats:count() as total by tags.gate limit:100
in:devices tags.site:ZZA stats:count() as total by tags.gate limit:100
in:devices stats:count() as total by metadata.integration_type
```

Devices missing the key are counted under `Unknown` rather than dropped. The
grouped result names the column with its full path (`tags.gate`), which is also
what `sort:` expects: `sort:tags.gate:asc`.

Groupable device fields: `type`, `vendor_name`, `risk_level`, `is_available`,
`is_active`, `gateway_id`, `tags.<key>`, `metadata.<key>`.

Grouped queries return at most **100** rows and default to **20**, so set
`limit:` explicitly when a dimension has more distinct values than that —
otherwise the chart silently shows a subset.

## Downsampling with `bucket`

For time-series charts, `bucket:` groups rows into fixed time buckets.

- `bucket:<duration>` — bucket width using `s|m|h|d` suffixes (e.g. `bucket:5m`).
- `agg:<function>` — bucket aggregation: `avg` (default), `min`, `max`, `sum`,
  `count`, `rate` (per-second rate of change for counters), `rate_sum` (per-second
  rates summed across the series collapsed into a bucket), or `last` (alias
  `latest`: the value of the newest sample in the bucket, for gauges such as a
  position or a battery level). `agg:last` reads raw samples on CNPG and on
  StarRocks. Hourly rollups have no newest-sample column, so this aggregate is
  never served from them.
- `series:<field>` — splits buckets into one series per distinct value.
- `value_field:<field>` — which numeric field to aggregate.

```srql
in:timeseries_metrics time:last_7d bucket:5m agg:avg series:metric_name
in:flows time:last_1h bucket:5m agg:sum value_field:bytes_total
in:timeseries_metrics metric_name:drone.position.lat time:last_2m bucket:2m agg:last series:tags.asset_id
```

Buckets are always **returned** oldest-first, because that is what a chart renders.
`sort:` instead chooses which end of the window `limit:` keeps when the range holds
more buckets than the limit allows:

- `sort:time:desc` (or no `sort:` reversal) keeps the **newest** buckets.
- `sort:time:asc` keeps the **oldest**.
- With no `sort:` at all, the oldest buckets are kept.

This matters on long ranges with narrow buckets: `time:last_30d bucket:5m` spans 8640
buckets, so `limit:100` returns a fraction of the window either way. Widen the bucket
rather than raising the limit — `bucket:1h` over 30 days is 720 buckets.

## Queryable entities

Target data with `in:<entity>`. Each entity exposes its own set of filterable
fields; using a field that the entity does not support returns an
`unsupported filter field` error naming the offending field.

| Entity (`in:`) | Aliases | Description |
|----------------|---------|-------------|
| `devices` | `device`, `device_inventory` | Device inventory and current state |
| `events` | `activity` | Normalized OCSF events and activity |
| `security_events` | | Control-plane security audit log. Requires `settings.audit.view`. |
| `logs` | — | Application and system logs (OpenTelemetry) |
| `threat_intel_matches` | `threat_intel_match`, `ioc_matches`, `ioc_match` | Current IP/CIDR cache-to-indicator memberships. Requires `observability.netflow.view`. |
| `flows` | `flow`, `network_activity` | NetFlow / network activity records (raw 5-tuples) |
| `attributed_flows` | `attributed_flow`, `flow_attributions`, `flow_attribution` | Flows joined with host process context (and optional public VIP owner) |
| `public_endpoints` | — | Kubernetes public VIP / Gateway ownership inventory (current snapshot) |
| `camera_sources` | `camera_source`, `cameras`, `camera` | Camera inventory with availability and viewable stream profiles. Requires `devices.view`. |
| `services` | `service` | Observed services and their availability |
| `gateways` | `gateway` | Gateway/agent operational state |
| `addon_statuses` | `addon_status` | Observed native add-on reports. Requires `devices.view`. |
| `addon_fleet` | `addon_fleets` | Native add-on assignments, observed health, freshness and version drift per agent. Requires `devices.view`. |
| `plugin_fleet` | `plugin_fleets` | WASM plugin assignments and current runtime evidence per partition and agent. Requires `plugins.view`. |
| `interfaces` | `interface`, `discovered_interfaces` | Discovered network interfaces (time-series) |
| `bmp_events` | `bmp_event`, `bmp_routing_events` | BGP Monitoring Protocol (BMP) routing events |
| `alerts` | `alert` | Generated alerts |
| `cpu_metrics` | `cpu` | CPU utilization time-series |
| `memory_metrics` | `memory` | Memory utilization time-series |
| `disk_metrics` | `disk` | Disk utilization time-series |
| `process_metrics` | `processes` | Per-process CPU/memory time-series |
| `timeseries_metrics` | `timeseries` | Generic time-series metrics (incl. SNMP) |
| `timeseries_metric_interface_hourly` | `timeseries_metrics_interface_hourly`, `interface_metrics_hourly` | Hourly interface counter rollups keyed by device and `if_index` (configurable retention, default 395 days; see `core.observabilityRetention.hourlyRollupDays`) |
| `timeseries_metric_disk_hourly` | `timeseries_metrics_disk_hourly` | Hourly `sysmon.disk` gauge rollups keyed by device and mount point (configurable retention, default 395 days; see `core.observabilityRetention.hourlyRollupDays`) |
| `snmp_metrics` | `snmp` | SNMP-collected metrics |
| `rperf_metrics` | `rperf` | rperf network performance metrics (shares the time-series schema) |
| `otel_metrics` | `metrics` | OpenTelemetry span-derived metrics |
| `traces` | `otel_traces`, `trace_spans` | OpenTelemetry trace spans |
| `otel_trace_summaries` | `trace_summaries`, `traces_summaries` | One row per trace. `service_name` matches any participating span (`service_set`). |
| `otel_services` | — | Catalog of OTel `service.name` values that reported logs, traces or metrics (not monitored service checks; see `services`). Requires at least one of `observability.logs.view`, `observability.traces.view`, `observability.metrics.view`. |
| `composite_results` | `composite_check_results`, `composite_verdicts` | Composite-check evaluations. Row queries return per-device verdicts; `stats:count()` groups by check / verdict / vantage (`input_*`). |
| `endpoint_packages` | `endpoint_package`, `packages`, `endpoint_inventory` | Current and historical endpoint software inventory (installed packages, CPE arrays) |
| `vulnerability_advisories` | `advisories`, `cves`, `vulnerability_advisory` | NVD/KEV advisory catalog. Default `current:true`. |
| `advisory_coordinates` | `advisory_cpes`, `cpe_coordinates` | Per-advisory CPE/PURL rows with version bounds. Not an alias of `cpes`. |
| `endpoint_vulnerability_assessments` | `endpoint_vulnerability_assessment`, `package_vulnerabilities`, `endpoint_vulnerability_matches`, `vulnerability_matches`, `cve_matches`, `advisory_matches` | Stable device/package/CVE assessments, including candidates and resolved history. |

> The engine also exposes specialized entities — device graph (`device_graph`),
> topology graph (`graph`, alias `graph_dql`), device updates (`device_updates`),
> Wi-Fi site mapping (`wifi_sites`, `wifi_access_points`, …), virtualization
> (`virtualization_hosts`, `virtualization_guests`, …), and field-survey
> datasets. They use the same `key:value` grammar described above.
>
> The two graph entities take a query string rather than field filters:
> `in:graph dql:"..."` runs read-only DQL against Dgraph, and
> `in:graph_cypher cypher:"..."` runs read-only openCypher against the Apache
> AGE graph. Mutations are refused in both. `in:graph` selected the device
> neighborhood in earlier releases; that entity is now reachable only as
> `in:device_graph`.

## Filterable fields by entity

Each subsection lists the fields you can filter and sort on for that entity. The
subsection heading matches the `in:` name used to select the entity.

### devices

| Field | Aliases | Description |
|-------|---------|-------------|
| `device_id` | `uid` | Unique device identifier |
| `hostname` | | Device hostname (supports wildcards) |
| `ip` | | IP address — supports wildcards, CIDR (`10.0.0.0/8`), and ranges (`10.0.0.10-10.0.0.50`) |
| `mac` | | MAC address (normalized; supports wildcards) |
| `gateway_id` | `gateway` | Associated gateway ID |
| `agent_id` | | Associated agent ID |
| `type` | `device_type` | Device type |
| `type_id` | | Numeric device type ID |
| `vendor_name` | `vendor` | Device vendor |
| `model` | | Device model |
| `risk_level` | `risk` | Risk classification |
| `is_available` | `available` | Currently reachable (`true`/`false`) |
| `is_active` | `active` | Lifecycle state (`true`/`false`) |
| `discovery_sources` | | Sources that discovered the device (array; list form) |
| `first_seen` | `first_seen_time` | When the device was first added. Accepts the same window tokens as `time:` (`last_7d`, `last_30d`, `today`, `[start,end]`). This does **not** change `time:`, which still filters `last_seen_time`. |
| `tags` | | Device tags (JSONB map). Bare `tags:<key>` tests whether the key exists; list form `tags:(a,b)` matches any of them. Sub-key form: `tags.<key>:<value>` |
| `metadata.<key>` | | Match an arbitrary metadata key, e.g. `metadata.integration_type:armis` |
| `cve` | `cve_id` | Device has an active, confirmed, affected assessment for this CVE (EXISTS). Case-insensitive. |
| `kev` | | Device has an active, confirmed, affected KEV assessment (`true`/`false`) |
| `source_retired` | | Record is marked `source_retired` (`true`/`false`); see the control tokens below. Replaces the default that hides marked records. |

Sortable fields include `hostname`, `ip`, `first_seen` / `first_seen_time`,
`last_seen` / `last_seen_time`, and `type_id`. There is no `cpe` filter on
`in:devices`; query `in:endpoint_packages` or `in:cve_matches`.

Control tokens: `include_inactive:true` returns devices regardless of lifecycle
state; `include_deleted:true` includes soft-deleted records and records marked
`source_retired`; `include_retired:true` includes records marked `source_retired`.

A record is marked `source_retired` when its source retired every id it held and
nothing else identifies it. Device queries and counts hide a marked record until it
is deleted after a grace period, unless the query asks for it with
`include_retired:true`, `include_deleted:true` or a `source_retired:` filter. A
`deleted:` filter does not show marked records.

### events

| Field | Aliases | Description |
|-------|---------|-------------|
| `id` | | Event identifier |
| `device_id` | `uid`, `source_device_uid` | Associated device |
| `class_uid` | | OCSF class UID |
| `category_uid` | | OCSF category UID |
| `type_uid` | | OCSF type UID |
| `activity_id` | | Activity ID |
| `activity_name` | | Activity name |
| `severity_id` | | Numeric severity ID |
| `severity` | | Severity label |
| `message` | `short_message` | Event message |
| `log_name` | | Log name or subject |
| `log_provider` | | Log provider |
| `log_level` | | Log level |
| `status` | | Status label |
| `status_id` | | Numeric status ID |
| `status_code` | | Status code |
| `status_detail` | | Status detail |
| `trace_id` | | OpenTelemetry trace ID |
| `span_id` | | OpenTelemetry span ID |

Sortable fields: `time` (aliases `event_timestamp`, `timestamp`).

### security_events

`in:security_events` reads the control-plane security
log behind Settings -> Audit -> Events. It requires `settings.audit.view`;
permission to read OCSF `events` or `security_findings` does not grant access.

Filters: `kind`, `severity`, `actor_id`, `ip`, `route`, `correlation_id`, `id`,
and `search`. Dedicated fields support equality, lists and `%` wildcards.
`search` matches a literal, case-insensitive substring across actor ID, IP,
route and correlation ID. Lists match any of the search terms; negation excludes
all matching terms. The builder offers equality and inequality for literal search.
Details are returned but cannot be searched or sorted.
Severity values are `info`, `warning` and `critical`; the catalog publishes the
current kind vocabulary.

The default time window is the last 24 hours. Results default to
`occurred_at DESC, id DESC`; explicit sorts also include an ID tie-breaker.
Limits and SRQL cursors follow the standard bounded pagination contract.

```text
in:security_events time:last_7d kind:login_failed severity:critical limit:25
in:security_events ip:192.0.2.8 route:/login time:last_24h
in:security_events search:invented-correlation limit:25
```

The Settings page displays 25 rows per page using timestamp/ID keyset cursors.
Filters survive paging; changing filters or clearing them returns to page 1.
Page 1 refreshes from storage on live notifications, so delayed or duplicate
notifications preserve ordering. Older pages pause live updates. Relative time
windows move with the current time; custom From/To values use UTC. Clear all
restores the last-24-hours window. Neither the page nor SRQL computes a total
count or loads the whole event set.

### logs

| Field | Aliases | Description |
|-------|---------|-------------|
| `id` | | Log record identifier |
| `device_id` | `uid`, `source_device_uid` | Associated device. Matches inventory uid/hostname/IP against log attributes and `source_ip` (syslog emitter IP). |
| `gateway_id` | | Associated gateway ID |
| `agent_id` | | Associated agent ID |
| `trace_id` | | OpenTelemetry trace ID |
| `span_id` | | OpenTelemetry span ID |
| `service_name` | `service` | Emitting service |
| `service_version` | | Service version |
| `service_instance` | | Service instance identifier |
| `source` | | Log source |
| `source_ip` | | Emitter IP (syslog `_remote_addr` / `source_ip`) |
| `scope_name` | | Instrumentation scope name |
| `scope_version` | | Instrumentation scope version |
| `severity_text` | `severity`, `level` | Severity text (e.g. `error`, `warn`) |
| `severity_number` | | Numeric severity |
| `body` | `message` | Log message body |

Sortable fields: `timestamp`, `severity_number`.

### threat_intel_matches

Current AlienVault OTX (and other IP/CIDR feed) matches. One row is one
endpoint-to-indicator membership. `evaluated_at` is cache lookup time, not flow
observation time. `indicator_match_count` is how many indicator CIDRs contain
that endpoint, not how many flows hit it.

| Field | Notes |
|---|---|
| `observed_ip` / `ip` | Cached endpoint |
| `source` | Feed source (`alienvault_otx`, …) |
| `indicator` | CIDR or IP |
| `severity` | Integer comparison |
| `stale:true` | Expired cache/indicator rows, labeled rather than mixed into the default |

Default sort: `evaluated_at DESC, observed_ip, indicator_id`. Default query
excludes expired rows.

```srql
in:threat_intel_matches source:alienvault_otx sort:evaluated_at:desc limit:100
```

### flows

| Field | Aliases | Description |
|-------|---------|-------------|
| `device_id` | | Associated device |
| `src_endpoint_ip` | `src_ip` | Source IP (supports wildcards) |
| `dst_endpoint_ip` | `dst_ip` | Destination IP (supports wildcards) |
| `ip` | `endpoint_ip` | Matches **either** endpoint — all traffic to or from an address |
| `cidr` | | Matches flows with **either** endpoint inside a CIDR block |
| `conversation_a_ip` | `conversation_min_ip` | Canonical first endpoint for bidirectional conversation grouping |
| `conversation_b_ip` | `conversation_max_ip` | Canonical second endpoint for bidirectional conversation grouping |
| `src_cidr` | | Source CIDR containment match |
| `dst_cidr` | | Destination CIDR containment match |
| `src_endpoint_port` | `src_port` | Source port |
| `dst_endpoint_port` | `dst_port` | Destination port |
| `port` | `endpoint_port` | Matches **either** endpoint port — e.g. `port:22` for SSH regardless of direction |
| `threat_matched` | | Live cache match on either flow endpoint. Interactive queries default to `time:last_24h` |
| `threat_source` | | Feed source on the live cache row |
| `threat_indicator` | | IP or CIDR of the matching indicator |
| `threat_observed_ip` | | Specific cached endpoint IP |
| `threat_severity` | | Compare live `max_severity` |
| `protocol_name` | | Protocol name |
| `protocol_num` | `proto` | Protocol number |
| `protocol_group` | `proto_group` | Protocol group |
| `direction` | | Flow direction |
| `flow_source` | `collector` | Originating collector |
| `app` | | Derived application classification label |
| `sampler_address` | | Flow exporter / sampler address |
| `exporter_name` | | Resolved exporter name |
| `in_if_name` | | Ingress interface name |
| `out_if_name` | | Egress interface name |
| `in_if_speed_bps` | | Ingress interface speed (bps) |
| `out_if_speed_bps` | | Egress interface speed (bps) |

Sortable fields: `time`, `bytes_total`, `packets_total`, `bytes_in`, `bytes_out`,
`packets_in`, `packets_out`.

Examples:

```srql
in:flows time:last_24h port:22 sort:time:desc limit:50
in:flows time:last_24h ip:198.51.100.10 sort:time:desc limit:50
in:flows time:last_1h dst_port:(443,8443)
```

Do **not** write `(dst_port:22 OR src_port:22)` — use `port:22` instead.

### attributed_flows

NetFlow rows that have been joined with host process attribution (netprobe) and,
when applicable, Kubernetes public VIP / Gateway ownership. Prefer this entity
when you need process, pod, or public-endpoint owner fields in the UI.

| Field | Aliases | Description |
|-------|---------|-------------|
| *(all core `flows` endpoint fields)* | | `src_ip`, `dst_ip`, `ip`, `port`, `src_port`, `dst_port`, `protocol_*`, … |
| `attribution_status` | `status` | `attributed` (has process pid) or `unmatched` |
| `process` | `process_name`, `comm` | Process name from host socket join |
| `pid` | `process_pid` | Process id |
| `cmdline` | `redacted_cmdline` | Redacted command line |
| `uid` | | Process uid |
| `container_id` | | Container id when known |
| `agent_id` | | Host agent that reported the process |
| `pod_name` | | Workload identity pod name |
| `pod_namespace` | `namespace` | Workload identity namespace |
| `container_name` | | Container name |
| `image` | `image_ref` | Container image |
| `service_name` | `public_endpoint_service`, `k8s_service` | Public endpoint Service / route target name |
| `gateway_name` | `public_endpoint_gateway` | Gateway API gateway name |
| `exposure_class` | `public_endpoint_class` | e.g. `Gateway`, `LoadBalancer` |
| `route_name` | `public_endpoint_route` | HTTPRoute / GRPCRoute name |
| `public_endpoint_namespace` | | Namespace of the public endpoint owner |

Sortable fields: same as `flows` (`time`, byte/packet totals).

Examples:

```srql
in:attributed_flows time:last_24h ip:198.51.100.10 sort:time:desc limit:50
in:attributed_flows time:last_24h service_name:serviceradar-web sort:time:desc limit:50
in:attributed_flows time:last_24h port:22 sort:time:desc limit:50
in:attributed_flows time:last_1h attribution_status:attributed process:sshd
```

**Raw vs attributed:** `in:flows port:22` can return hundreds of SSH 5-tuples
while `in:attributed_flows port:22` is empty if no host process join landed on
those sockets. Public VIP ownership (`service_name:`, `exposure_class:`) only
appears after the central correlator stamps `attribution.public_endpoint`.

### public_endpoints

Current Kubernetes public VIP inventory (LoadBalancer / Gateway / ExternalIP).
Not a time-series entity — omit or ignore `time:` for inventory scans.

| Field | Aliases | Description |
|-------|---------|-------------|
| `ip` | | Public VIP address |
| `hostname` | | Hostname if recorded |
| `port` | | Listener port |
| `protocol` | | e.g. `TCP` |
| `namespace` | | Kubernetes namespace |
| `cluster_id` | | Cluster id |
| `exposure_class` | | `Gateway`, `LoadBalancer`, … |
| `service_name` | | Service or route backend name |
| `gateway_name` | | Gateway name |
| `route_name` | | Route name |

Examples:

```srql
in:public_endpoints port:22 limit:50
in:public_endpoints exposure_class:Gateway sort:ip:asc
in:public_endpoints ip:198.51.100.10
```

### camera_sources

Camera inventory for relay viewing: each camera's owning device, availability and
the relay-eligible stream profiles a viewer can open through the dashboard camera
API. `source_url`, per-profile `source_url_override`, and `metadata` are never
returned. RTSP URLs often embed credentials, and the relay opens the upstream
stream on the agent, so a viewer never needs them. Filtering or sorting on those
fields is rejected. Not a time-series entity; `time:` filters on `updated_at`.

| Field | Aliases | Description |
|-------|---------|-------------|
| `display_name` | `name` | Camera display name |
| `vendor` | | Camera vendor, e.g. `ubiquiti`, `axis` |
| `vendor_camera_id` | `camera_id` | Vendor-side camera identifier |
| `device_uid` | `device_id`, `uid` | Owning device |
| `availability_status` | `availability`, `status` | e.g. `available`, `unavailable` |
| `assigned_agent_id` | `agent_id` | Agent that pulls the stream |
| `assigned_gateway_id` | `gateway_id` | Gateway on the relay path |
| `last_event_type` | | Type of the camera's last event |
| `viewable` | `relay_eligible`, `has_viewable_profile` | `true` for cameras with at least one relay-eligible profile |

Each row carries `stream_profiles`: a list of `{id, profile_name, vendor_profile_id,
codec_hint, container_hint, rtsp_transport, last_seen_at}` for relay-eligible
profiles only.

Examples:

```srql
in:camera_sources viewable:true sort:display_name:asc
in:camera_sources availability:available vendor:ubiquiti
in:cameras device_uid:(dev-a,dev-b)
```

### services

| Field | Aliases | Description |
|-------|---------|-------------|
| `service_name` | `name` | Service name |
| `service_id` | `uid` | Service identifier |
| `service_type` | `type` | Service type |
| `gateway_id` | | Associated gateway ID |
| `agent_id` | | Associated agent ID |
| `partition` | | Partition identifier |
| `message` | | Status message |
| `available` | | Availability (`true`/`false`) |

Sortable fields: `timestamp` / `last_seen`, `service_name` / `name`,
`service_type` / `type`.

### gateways

| Field | Description |
|-------|-------------|
| `gateway_id` | Gateway identifier |
| `status` | Gateway status |
| `component_id` | Component identifier |
| `registration_source` | Registration source |
| `spiffe_identity` | SPIFFE identity |
| `created_by` | Creator identifier |
| `is_healthy` | Health status (`true`/`false`) |

Sortable fields: `last_seen`, `first_seen`, `first_registered`, `gateway_id`,
`status`, `agent_count`, `checker_count`, `updated_at`.

### interfaces

Interface observations are stored as time-series data. Use `latest:true` to return
the most recent record per interface.

| Field | Aliases | Description |
|-------|---------|-------------|
| `device_id` | | Device identifier |
| `device_ip` | `ip` | Device IP address |
| `interface_uid` | | Stable interface identifier (per device) |
| `gateway_id` | | Associated gateway ID |
| `agent_id` | | Associated agent ID |
| `if_name` | | Interface name |
| `if_descr` | `description` | Interface description |
| `if_alias` | | Interface alias |
| `if_index` | | Interface index (ifIndex) |
| `if_type` | | Interface type identifier (ifType) |
| `if_type_name` | | Interface type (human-readable) |
| `interface_kind` | | Classification (physical, virtual, loopback, tunnel, …) |
| `if_phys_address` | `mac` | Physical (MAC) address |
| `if_admin_status` | `admin_status` | Administrative status |
| `if_oper_status` | `oper_status`, `status` | Operational status |
| `if_speed` | `speed`, `speed_bps` | Interface speed |
| `mtu` | | Interface MTU |
| `duplex` | | Interface duplex |
| `ip_addresses` | `ip_address` | IP addresses assigned to the interface (list form) |

Sortable fields: `timestamp`, `device_ip`, `device_id`, `interface_uid`, `if_name`,
`if_descr`, `if_index`, `if_type`, `if_type_name`, `interface_kind`, `speed_bps`,
`mtu`.

### bmp_events

`in:bmp_events` is how you query BGP routing data — peer events and prefix
advertisements collected via the BGP Monitoring Protocol (BMP).

| Field | Description |
|-------|-------------|
| `id` | Event identifier |
| `event_type` | BMP event type |
| `router_id` | Reporting router ID |
| `router_ip` | Reporting router IP |
| `peer_ip` | BGP peer IP |
| `peer_asn` | BGP peer ASN (numeric) |
| `local_asn` | Local ASN (numeric) |
| `prefix` | Advertised/withdrawn prefix |
| `message` | Event message |
| `raw_data` | Raw event payload |
| `severity_id` | Numeric severity ID |

Sortable fields: `time` (aliases `event_timestamp`, `timestamp`), `created_at`,
`severity_id`.

### alerts

| Field | Description |
|-------|-------------|
| `id` | Alert identifier |
| `title` | Alert title |
| `description` | Alert description |
| `severity` | Alert severity |
| `status` | Alert status |
| `source_type` | Source type |
| `source_id` | Source identifier |
| `device_uid` | Associated device |
| `agent_uid` | Associated agent |
| `metric_name` | Metric that triggered the alert |
| `comparison` | Comparison operator used |
| `acknowledged_by` | Who acknowledged the alert |
| `resolved_by` | Who resolved the alert |
| `escalation_reason` | Escalation reason |

Sortable fields: `triggered_at` / `timestamp`, `severity`, `status`, `title`.

### cpu_metrics

| Field | Description |
|-------|-------------|
| `gateway_id` | Associated gateway ID |
| `agent_id` | Associated agent ID |
| `host_id` | Host identifier |
| `device_id` | Device identifier |
| `partition` | Partition identifier |
| `cluster` | Cluster name |
| `label` | Label |
| `core_id` | CPU core identifier |
| `usage_percent` | CPU usage percentage |
| `frequency_hz` | CPU frequency in Hz |

Sortable fields: `timestamp`, `usage_percent`, `gateway_id`, `device_id`,
`host_id`, `partition`, `core_id`.

### memory_metrics

| Field | Description |
|-------|-------------|
| `gateway_id` | Associated gateway ID |
| `agent_id` | Associated agent ID |
| `host_id` | Host identifier |
| `device_id` | Device identifier |
| `partition` | Partition identifier |
| `usage_percent` | Memory usage percentage |
| `total_bytes` | Total memory in bytes |
| `used_bytes` | Used memory in bytes |
| `available_bytes` | Available memory in bytes |

Sortable fields: `timestamp`, `usage_percent`, `gateway_id`, `device_id`,
`host_id`.

### disk_metrics

| Field | Description |
|-------|-------------|
| `gateway_id` | Associated gateway ID |
| `agent_id` | Associated agent ID |
| `host_id` | Host identifier |
| `device_id` | Device identifier |
| `partition` | Partition identifier |
| `mount_point` | Filesystem mount point |
| `device_name` | Device name |
| `usage_percent` | Disk usage percentage |
| `total_bytes` | Total disk space in bytes |
| `used_bytes` | Used disk space in bytes |
| `available_bytes` | Available disk space in bytes |

Sortable fields: `timestamp`, `usage_percent`, `gateway_id`, `device_id`,
`host_id`, `mount_point`.

### process_metrics

| Field | Description |
|-------|-------------|
| `gateway_id` | Associated gateway ID |
| `agent_id` | Associated agent ID |
| `host_id` | Host identifier |
| `device_id` | Device identifier |
| `partition` | Partition identifier |
| `pid` | Process ID |
| `name` | Process name |
| `status` | Process status |
| `start_time` | Process start time |
| `cpu_usage` | Process CPU usage |
| `memory_usage` | Process memory usage |

Sortable fields: `timestamp`, `cpu_usage`, `memory_usage`, `pid`, `name`.

### timeseries_metrics

`in:timeseries_metrics` (and the `snmp_metrics` / `rperf` aliases that share this
schema) cover generic time-series data, including SNMP counters.

| Field | Description |
|-------|-------------|
| `gateway_id` | Associated gateway ID |
| `agent_id` | Associated agent ID |
| `metric_name` | Name of the metric |
| `metric_type` | Type of metric |
| `device_id` | Device identifier |
| `target_device_ip` | Target device IP address |
| `partition` | Partition identifier |
| `if_index` | Interface index |
| `value` | Metric value |

Sortable fields: `timestamp`, `gateway_id`, `metric_name`, `metric_type`,
`device_id`, `value`.

### timeseries_metric_disk_hourly

`in:timeseries_metric_disk_hourly` reads the hourly continuous aggregate of
`sysmon.disk` gauges. Each row is one (device, series, mount point) bucket, so
a filling data volume is not averaged into its host's other filesystems. Rows
are kept for the configured retention (default 395 days; operator-configurable via `core.observabilityRetention.hourlyRollupDays`); `time:` bounds match whole hourly buckets. The entity
returns rows only: `stats:`, `bucket:` and `agg:` are rejected.

| Field | Description |
|-------|-------------|
| `device_id` | Device identifier |
| `metric_type` | Metric type (`sysmon.disk`) |
| `metric_name` | Metric name, e.g. `disk.used_percent` |
| `series_key` | Canonical series key of the rolled-up samples |
| `mount_point` | Filesystem mount point from the sample tags |
| `avg_value` | Hourly mean of the gauge |
| `min_value` | Hourly minimum |
| `max_value` | Hourly maximum |
| `sample_count` | Samples in the bucket |

Sortable fields: `bucket` (also `timestamp`), `device_id`, `metric_type`,
`metric_name`, `series_key`, `mount_point`, `avg_value`, `min_value`,
`max_value`, `sample_count`. Default order is `bucket` descending.

```text
in:timeseries_metric_disk_hourly metric_name:"disk.used_percent" device_id:"sr:host01" time:last_30d sort:bucket:asc
```

### otel_metrics

| Field | Aliases | Description |
|-------|---------|-------------|
| `trace_id` | | OpenTelemetry trace ID |
| `span_id` | | Span identifier |
| `service_name` | `service` | Emitting service |
| `span_name` | | Span name |
| `span_kind` | | Span kind |
| `metric_type` | `type` | Metric type |
| `component` | | Component name |
| `level` | | Level |
| `http_method` | | HTTP method |
| `http_route` | | HTTP route |
| `http_status_code` | | HTTP status code |
| `grpc_service` | | gRPC service name |
| `grpc_method` | | gRPC method name |
| `grpc_status_code` | | gRPC status code |
| `is_slow` | | Slow-request flag (`true`/`false`) |

Sortable fields: `timestamp`, `service_name` / `service`, `metric_type` / `type`,
`duration_ms`.

### traces

| Field | Aliases | Description |
|-------|---------|-------------|
| `trace_id` | | OpenTelemetry trace ID |
| `span_id` | | Span identifier |
| `parent_span_id` | | Parent span identifier |
| `service_name` | | Emitting service |
| `service_version` | | Service version |
| `service_instance` | | Service instance identifier |
| `scope_name` | | Instrumentation scope name |
| `scope_version` | | Instrumentation scope version |
| `name` | `span_name` | Span name |
| `status_message` | | Status message |
| `status_code` | | Numeric status code |
| `kind` | `span_kind` | Span kind (integer) |

Sortable fields: `timestamp`, `start_time_unix_nano`, `end_time_unix_nano`,
`service_name`.

### otel_trace_summaries

`service_name` matches a trace when any participating span (`service_set`) has that
service, not only the root span. Use an exact name (`service_name:checkout`) or a list
(`service_name:(checkout,cart)`); `!service_name:` also matches traces with no recorded
service set. `%` wildcards are rejected on this field; use `root_service_name` for pattern
matches.

### otel_services

`in:otel_services` reads the service catalog that EventWriter maintains from persisted
logs, traces and metrics. It is best-effort and throttled, and entries expire after 30
days without activity. The catalog is CNPG state in every storage mode.

| Field | Description |
|-------|-------------|
| `service_name` | Service name; supports `%` wildcards |
| `signal` | `logs`, `traces` or `metrics`; a list is allowed, a repeated or negated `signal:` is rejected |

Rows carry `signals` and per-signal last-seen timestamps (`logs_last_seen`,
`traces_last_seen`, `metrics_last_seen`) plus `last_seen`. All of them are derived only
from the signals the caller may view: without `signal:` the query covers every permitted
signal, and requesting a signal the caller cannot view is forbidden (403). Sortable
fields: `service_name`, `last_seen` (default, descending). The default limit is 50 and the
maximum is 500. `stats:"count() as total"` is the only aggregation.

```text
in:otel_services signal:traces service_name:%pay% sort:last_seen:desc limit:50
```

### endpoint_packages

| Field | Aliases | Description |
|-------|---------|-------------|
| `device_uid` | `device_id` | Host that has the package |
| `name` | `package` | Package name |
| `version` | | Installed version |
| `package_manager` | `manager` | Package manager (`dpkg`, `rpm`, …) |
| `purl_canonical` | `canonical_purl`, `purl` | Canonical PURL |
| `cpe` | `cpes` | Installed CPE array overlap (not NVD version matching) |
| `cve` | `cve_id` | Package has an active, confirmed, affected assessment for this CVE on the same device (EXISTS) |
| `kev` | | Package has an active, confirmed, affected KEV assessment on the same device |
| `current` | | Current inventory row (`true`/`false`) |

`rollup_stats:current_counts` and `rollup_stats:current_cpe_counts` read
maintained count tables, not ad hoc `GROUP BY`.

### vulnerability_advisories

| Field | Aliases | Description |
|-------|---------|-------------|
| `cve` | `cve_id` | CVE identifier (uppercased on equality) |
| `advisory_id` | | Source advisory id |
| `provider` | | Feed provider |
| `feed_key` | | Feed key (`nist-nvd2`, `cisa-kev`, …) |
| `severity` | | Severity label |
| `cvss_score` | | Numeric CVSS (supports `>=`, `>`) |
| `kev` | | Listed in an enabled KEV feed |
| `exploit_available` | | Exploit available flag |
| `current` | | Current generation (default `true`) |
| `title` | | Advisory title |
| `cpe` / `cpe_vendor` / `cpe_product` | | EXISTS against `advisory_coordinates` |

`time:` filters `published_at`. Projection omits `raw` and
`affected_coordinates`. `stats:count()` groups by `severity`, `kev`,
`provider`, `feed_key`, `cve_id`. No `downsample` / `rollup_stats`.
Positive CPE component filters must match the same coordinate row. Negated CPE
component filters exclude an advisory when any of its coordinates matches that
component.

### advisory_coordinates

| Field | Aliases | Description |
|-------|---------|-------------|
| `cve` | `cve_id` | Joined advisory CVE |
| `coordinate_type` | | `cpe`, `purl`, or `vendor_product` |
| `value` | `cpe`, `cpes` | Coordinate string (`ILIKE` with `%`) |
| `cpe_vendor` / `cpe_product` / `cpe_part` / `cpe_version` | | Parsed CPE 2.3 components |
| `advisory_ref` | | Parent advisory UUID |
| `kev` | | Joined advisory KEV flag |
| `current` | | Joined advisory is current (default `true`) |

`stats:count()` requires a selective filter (CVE, vendor+product, or CPE
value). Version-bound columns are returned; they are not evaluated against
installed versions.

### endpoint_vulnerability_assessments

| Field | Aliases | Description |
|-------|---------|-------------|
| `device_uid` | `device_id` | Assessed device |
| `cve` | `cve_id` | Assessed CVE |
| `status` | | `active` or `resolved` lifecycle state |
| `assessment` | | `confirmed` or `candidate` |
| `disposition` | | `affected`, `fixed`, `not_affected`, `under_investigation`, or `unknown` |
| `authority` / `freshness` | | Applicability authority and evidence freshness |
| `authority_generation` / `authority_as_of` | | Authority audit generation and RFC 3339 as-of time; both support scalar comparisons |
| `applicability_reason` | | Explanation for the current decision |
| `package_name` / `installed_version` | | Assessed package and installed version |
| `package_identity_key` / `source_scope` | | Stable logical package identity and observation scope |
| `package_namespace` / `package_release` | `namespace`, `release`, `distro` | Provider namespace and release scope |
| `package_purl` | `purl`, `purl_canonical` | Canonical package URL captured by the assessment |
| `fixed_version` | | Provider fixed boundary when known |
| `kev` | | KEV overlay |
| `exploit_available` | | Exploit flag |
| `cvss_score` / `severity` | | Aggregated advisory priority |
| `cpe` | `coordinate_value` | Correlated raw match evidence, when present |
| `advisory_ref` | | Advisory UUID resolved through correlated raw-match or normalized assertion evidence |
| `epss_score` / `due_date` / `ransomware_use` | | Lifted from assessment metadata |

Row browsing returns confirmed, candidate, and resolved assessments unless
explicitly filtered; it has no implicit active-only predicate. An unqualified
assessment `stats:count()` counts those persisted audit/state rows and is not an
exposure count. A row or count is actionable only when `status:active`,
`assessment:confirmed`, and `disposition:affected` all hold. `time:` filters
`last_seen_at`. Default sort puts actionable rows first, then KEV, exploit,
CVSS, and last seen.

## Error handling

| Message | Cause / fix |
|---------|-------------|
| `queries must include an in:<entity> token` | Add an `in:<entity>` selector. |
| `unsupported entity '<x>'` | The entity name is not recognized. See [Queryable entities](#queryable-entities). |
| `unsupported filter field` | The field is not valid for the chosen entity. Check [Filterable fields by entity](#filterable-fields-by-entity). |
| `unsupported time token` / `invalid time literal` | The `time:` value is malformed. Use `last_<n><unit>`, `today`/`yesterday`, or `[start,end]`. |
| `time range cannot exceed 90 days` | Narrow the window, or use a metric entity with `stats:`/`bucket:` for longer ranges. |
| `invalid limit` / `limit must be a positive integer` | `limit:` requires a positive integer. |
| `expected scalar value` / `expected list value` | Operator/value mismatch — e.g. a list value where a scalar is expected. |
| `InvalidRequest` on `in:composite_results stats:` | Unsupported aggregation (only `count()`) or group field. See [Composite-result stats](#composite-result-stats). |
| `advisory_coordinates stats require a selective filter` | Add `cve:`, `cpe_vendor`+`cpe_product`, or a CPE `value` before `stats:count()`. |

## See also

- [SRQL Tutorial](./srql-tutorial.md) — step-by-step introduction for new users.
- [SRQL Cookbook](./srql-cookbook.md) — task-oriented copy-paste recipes.
- [Threat Investigation](./threat-investigation.md) — CVE, CPE, KEV, and matcher
  queries.

## Agent extension fleet queries

Native add-ons and WASM plugins have separate entities. `addon_fleet` (alias
`addon_fleets`) requires `devices.view`; `plugin_fleet` (alias `plugin_fleets`)
requires `plugins.view`. Both execute scoped Ash reads. Translation returns a
validated `read_model` plan with empty SQL; execute it through web-ng's query
API, which also supports Arrow responses and signed cursor pagination. Direct
execution through the standalone Rust query engine rejects fleet queries.

```srql
in:addon_fleet addon_id:example-collector assigned:true sort:agent_uid:asc
in:addon_fleet addon_id:example-collector category:action_required
in:addon_fleet addon_id:example-collector stale:true
in:addon_fleet addon_id:example-collector version_drift:true
in:plugin_fleet plugin_id:example-check enabled:true sort:partition_id:asc
in:plugin_fleet plugin_id:example-check category:action_required
in:plugin_fleet plugin_id:example-check partition_id:partition-a stale:true
```

Native fleet rows reuse the native fleet UI's health classification and include
assigned package/version, observed state/version, active flag, degradation
reason, report/health/scan timestamps, evidence age, rollout state, and reason
code. Disabled native assignments are history, so a runtime without an enabled
assignment has `assigned:false`. `addon_statuses` / `addon_status` retain their
existing status-only behavior and newest-report ordering.

WASM fleet rows include partition, agent, plugin, package/version, assignment
source/policy, enabled state, cadence, latest runtime evidence, and the reported
`result_status` (`OK`, `WARNING`, `CRITICAL`, or `UNKNOWN`). An otherwise healthy
runtime with a fresh warning requires action even when it reports availability.
The join matches both partition and agent; legacy name-only evidence is used
only for an unambiguous plugin name. Disabled assignments remain visible as
`expected_inactive`, and identified runtimes without an assignment are
`observed_only`. Assignment placeholders appear as `pending` or `ready`, with
no result timestamp or inferred availability. They are never reported results.

`stale` compares native evidence age with the configured add-on freshness
threshold (180 seconds by default). WASM evidence is stale after the greater of
180 seconds and three assignment intervals, using a 60-second interval for
observed-only rows. `stale` describes evidence age independently of health
category: package and rollout problems, disabled assignments, and observed-only
runtimes can take classification precedence over stale evidence. Missing evidence has null
timestamps and age and `stale:false`; it is not a fresh success. `time:` filters
the last reported observation, excluding missing evidence. Omit `time:` when
investigating assignments that have not reported.

For WASM results, `reported_at` uses the logical observation timestamp resolved
by the existing plugin state contract, with the stored observation timestamp as
its fallback. Reported-result markers must authenticate the snapshot identity,
payload, and physical timestamp. Freshness and timestamp filters use the
resolved observation time.

`version_drift` is null unless both desired and observed versions are known.
WASM results do not currently carry a host-authored version; an explicitly
reported `package_version` is shown when present, without inferring it from the
assignment. `assignment_drift` compares a reported assignment ID with the
current assignment; it is null when either ID is unknown. Otherwise healthy
WASM results with known drift require action.

`last_success_at` and `last_failure_at` describe availability of the latest WASM
result: `available:true` sets the former and `available:false` sets the latter.
A warning can therefore have `last_success_at` set and category
`action_required`. These fields do not scan historical telemetry.
`last_error` is the standardized `plugin_result_unavailable` code for a failed
latest result. Raw messages, result details, assignment params, permissions and
resource overrides, and host-only credential material are excluded.

Fleet queries support equality, negation, list membership, text wildcards,
numeric/timestamp comparisons, sorting, limits, and cursors. Null sort values
come last; identity fields break ties for stable pagination. Stats, rollups,
and downsampling fail explicitly.
