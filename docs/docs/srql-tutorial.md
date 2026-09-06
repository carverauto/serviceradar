---
title: SRQL Tutorial
---

# SRQL Tutorial

This is a hands-on, step-by-step introduction to **SRQL** — the ServiceRadar Query
Language. SRQL is a compact `key:value` language for asking questions about your
network: which devices are online, what events fired last night, which flows moved
the most traffic, and more.

You do not need to know SQL. By the end of this page you will be able to write your
own queries against devices, events, logs, and metrics.

> **Where to run queries:** Type SRQL into the ServiceRadar query bar in the web UI.
> Every example below is a complete, runnable query — copy it, paste it, run it.

When you want the full list of entities, fields, and operators, see the
[SRQL Reference](./srql-language-reference.md). For ready-made queries grouped by
task, see the [SRQL Cookbook](./srql-cookbook.md).

---

## Step 1: Your first query

Every SRQL query must say **what kind of data** you want. You do that with the
`in:` selector. The simplest possible query is just an entity:

```srql
in:devices
```

This returns a page of devices from your inventory. That is it — one token, one
result set.

If you forget the `in:` selector, SRQL rejects the query with
`queries must include an in:<entity> token`. The entity always comes first in
spirit, even though tokens can appear in any order.

---

## Step 2: Add a filter with `key:value`

A query with no filters returns *everything* (up to the page limit). To narrow it
down, add a `key:value` filter. Keys are field names; values are what you want to
match.

Find a single device by hostname:

```srql
in:devices hostname:edge-router-01
```

Find devices made by a particular vendor:

```srql
in:devices vendor_name:Cisco
```

Plain English: "give me devices where `vendor_name` equals `Cisco`." Tokens are
separated by spaces, and you can stack as many filters as you like (see Step 5).

If a value contains spaces, wrap it in quotes:

```srql
in:devices vendor_name:"Axis Communications"
```

---

## Step 3: Match partial text with wildcards

You rarely know the exact hostname. Use the `%` wildcard to match *part* of a
string. `%` stands for "any run of characters."

Every device whose hostname contains `cam`:

```srql
in:devices hostname:%cam%
```

Every hostname that *starts with* `router-`:

```srql
in:devices hostname:router-%
```

Every hostname that *ends with* `.lab`:

```srql
in:devices hostname:%.lab
```

Text matching with `%` is case-insensitive, so `%CAM%` and `%cam%` behave the same.

To invert a filter, put `!` in front of the key. "Devices whose hostname does *not*
contain `test`":

```srql
in:devices !hostname:%test%
```

---

## Step 4: Numbers, ranges, and lists

For numeric fields you can use comparison operators directly in the value:

```srql
in:cpu_metrics usage_percent:>80
```

That reads "CPU metrics where usage is greater than 80 percent." The supported
operators are `>`, `>=`, `<`, and `<=`.

To express a *range*, repeat the field with two bounds:

```srql
in:cpu_metrics usage_percent:>80 usage_percent:<95
```

To match **any one of several values**, use a comma-separated list in parentheses.
This behaves like SQL `IN`:

```srql
in:services service_type:(ssh,sftp,telnet)
```

That returns services whose type is `ssh` *or* `sftp` *or* `telnet`. Prefix the key
with `!` to exclude the whole list instead:

```srql
in:services !service_type:(telnet)
```

---

## Step 5: Combine filters

Listing several filters together means "match **all** of them" (logical AND).
Build up a precise query one token at a time:

```srql
in:devices vendor_name:Cisco hostname:%core% is_available:true
```

Plain English: "Cisco devices whose hostname contains `core` and that are currently
available." Boolean fields like `is_available` accept `true` or `false`.

There is no `OR` keyword between separate filters — when you need OR semantics for a
single field, use the list form from Step 4.

For **NetFlow either-side** questions (“SSH on port 22 either direction”, “all
traffic involving this VIP”), do **not** write `(dst_port:22 OR src_port:22)`.
Use the bidirectional helpers instead:

```srql
in:flows time:last_24h port:22 sort:time:desc limit:50
in:flows time:last_24h ip:198.51.100.10 sort:time:desc limit:50
```

`port:` matches either endpoint port; `ip:` matches either endpoint address.
See the [SRQL Cookbook](./srql-cookbook.md#netflow-traffic-queries) for more
flow and attributed-flow recipes.

---

## Step 6: Scope queries to a time window

Event, log, flow, and metric data is time-series data. Use `time:` to choose the
window you care about. The most common form is a relative window:

```srql
in:events time:last_24h
```

`last_24h` means "the last 24 hours." The pattern is `last_<number><unit>`, where
the unit is `m` (minutes), `h` (hours), `d` (days), or `y` (years):

```srql
in:logs time:last_30m
in:flows time:last_7d
```

You can also use the shortcuts `time:today` and `time:yesterday`, or an absolute
range with bracket syntax:

```srql
in:events time:[2026-01-01T00:00:00Z,2026-01-02T00:00:00Z]
```

If you leave one side of the bracket blank, the range is open-ended:

```srql
in:events time:[2026-01-01T00:00:00Z,]
```

> **Tip:** Always add a `time:` window to event, log, flow, and metric queries. It
> keeps results fast and relevant. Most time windows are capped at 90 days.

---

## Step 7: Sort and limit results

By default SRQL returns a page of results in a sensible default order. Take control
with `sort:` and `limit:`.

`limit:<n>` caps how many rows come back:

```srql
in:devices limit:25
```

`sort:<field>` orders the results. Add `:asc` or `:desc` for direction (`desc` is
the default if you omit it):

```srql
in:devices sort:last_seen:desc limit:10
```

That reads "the 10 most recently seen devices." Put it all together — entity,
filter, time window, sort, and limit:

```srql
in:devices is_available:true time:last_7d sort:last_seen:desc limit:20
```

`time:` on devices is last seen. To ask "added recently" instead, filter
`first_seen:`:

```srql
in:devices first_seen:last_30d sort:first_seen:desc limit:20
```

---

## Step 8: Query across different entities

SRQL is the same language regardless of *what* you query. Once you know the pattern,
switching domains is just changing the `in:` selector and the field names.

**Events** — recent high-severity events:

```srql
in:events time:last_24h severity_id:>3 sort:time:desc limit:50
```

**Logs** — error-level log lines from one service:

```srql
in:logs service_name:serviceradar-core severity_text:error time:last_1h
```

**Flows** — NetFlow traffic to a destination in the last hour:

```srql
in:flows dst_ip:8.8.8.8 time:last_1h sort:bytes_total:desc
```

**Metrics** — hosts with high memory usage right now:

```srql
in:memory_metrics usage_percent:>90 time:last_15m sort:usage_percent:desc
```

Each entity exposes its own set of filterable fields. The
[SRQL Reference](./srql-language-reference.md#queryable-entities) lists every entity
and its fields.

---

## Step 9: Summarize with `stats`

When you want a *count* or a *total* rather than a list of rows, use `stats:`. The
form is `stats:<function>(<field>) as <alias>`, optionally followed by
`by <field>` to group.

Count devices by type:

```srql
in:devices stats:count() as total by type
```

Average CPU usage over the last day:

```srql
in:cpu_metrics time:last_24h stats:avg(usage_percent) as avg_cpu
```

Total bytes per source IP for the busiest talkers:

```srql
in:flows time:last_1h stats:sum(bytes_total) as bytes by src_ip sort:bytes:desc limit:10
```

The available aggregation functions are `count`, `sum`, `avg`, `min`, and `max`.

---

## Where to go next

- **[SRQL Reference](./srql-language-reference.md)** — the complete grammar, every
  queryable entity, all filterable fields, operators, and time syntax.
- **[SRQL Cookbook](./srql-cookbook.md)** — copy-paste recipes for everyday tasks:
  finding devices, inspecting events and logs, NetFlow analysis, BGP routing, and
  building queries that feed alert rules.
- **[Threat Investigation](./threat-investigation.md)** — CVE, CPE, KEV, and
  matcher queries for fleet exposure.

Common mistakes to avoid as you start out:

- Forgetting `in:` — every query needs an entity.
- Using a field that does not belong to the entity — SRQL returns an
  `unsupported filter field` error naming the bad field. Check the Reference.
- Putting `!` on the value instead of the key. Negation is `!key:value`, never
  `key:!value`.
