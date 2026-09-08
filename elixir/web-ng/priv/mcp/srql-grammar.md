# SRQL grammar (for MCP agents)

SRQL is ServiceRadar's read-only query language. It is **not SQL, not JSON,
and not a REST filter**. Tokens are whitespace-separated `key:value` pairs.

This page is the grammar. Entity **fields** live in `get_srql_catalog`.
Copy-paste recipes live at `serviceradar://srql/cookbook`. Entity ids live at
`serviceradar://srql/entities`.

## Workflow

1. Read this grammar if you have not already.
2. Read `serviceradar://srql/entities` and pick one `in:` id.
3. Call `get_srql_catalog` with `entity` set to that id (the unfiltered catalog
   is ~50 entities — do not dump it unless you truly need every field).
4. Call `execute_srql` with a complete query string.

## Shape

```
in:<entity> [field:value ...] [time:<window>] [sort:<field>[:asc|:desc]] [limit:<n>] [stats:<expr>] [bucket:<duration>]
```

Every query **must** include exactly one `in:<entity>` token. Tokens may appear
in any order. AND is implicit: listing two filters means both must match.

```
in:devices hostname:%core% vendor_name:Cisco time:last_7d sort:last_seen:desc limit:20
```

## Operators (inferred from the value)

| You write | Meaning |
|-----------|---------|
| `field:value` | equals |
| `!field:value` | not equals (bang is on the **key**) |
| `field:%text%` | contains (case-insensitive) |
| `!field:%text%` | does not contain |
| `field:(a,b,c)` | one of (OR on **this field only**) |
| `!field:(a,b,c)` | none of |
| `field:>n` `field:>=n` `field:<n` `field:<=n` | numeric compare |

There is **no** cross-field `OR`. Do not write `(dst_port:22 OR src_port:22)` —
that tokenizes as one broken `key:value` and returns empty or invalid. Use the
bidirectional helpers below, or two queries.

`key:!value` is invalid. Negation is `!key:value`.

Quote values that contain spaces: `vendor_name:"Axis Communications"`. Single
quotes, double quotes, and backticks are accepted. Keys are case-insensitive.

## Wildcards

`%` is the only wildcard (any run of characters). No `%` means exact match.

```
in:devices hostname:router-%
in:devices hostname:%.lab
in:devices hostname:%core%
```

Do not wrap IP addresses in `%` unless you intend a substring match
(`%10.0.0.1%` also matches `110.0.0.1`). Prefer CIDR helpers for networks.

## Time

`time:` (alias `timeFrame:`). Relative: `time:last_30m`, `last_24h`, `last_7d`,
`last_1y`. Units: `m`, `h`, `d`, `y`. Shortcuts: `time:today`, `time:yesterday`.
Absolute: `time:[2026-01-01T00:00:00Z,2026-01-02T00:00:00Z]` (RFC 3339; a blank
side is open-ended). Most queries cap at 90 days.

On inventory (`in:devices`), `time:` still means last-seen, not first-seen.
Use `first_seen:last_30d` for newly discovered devices.

## Sort and limit

- `sort:<field>[:asc|:desc]` — default direction is `desc`. Multiple keys:
  `sort:time:desc,bytes_total`. `order:` is an alias.
- `limit:<n>` — positive integer; the engine enforces a maximum.

## Lists, ranges, IPs

- List OR: `severity_text:(error,warn)` or `dst_port:(443,8443)`. Max 200 values.
- Numeric range: repeat the field, `usage_percent:>80 usage_percent:<95`.
- Device IP: `ip:10.20.0.10`, `ip:10.20.0.0/16`, or `ip:10.20.0.10-10.20.0.50`.
- Array containment (devices): `discovery_sources:(armis)`.

## Bidirectional flow helpers

On `in:flows` and `in:attributed_flows`:

- `ip:` / `endpoint_ip:` — either endpoint IP
- `port:` / `endpoint_port:` — either endpoint port
- `cidr:` — either endpoint in a CIDR
- `tag:` — either side prefix tag; `src_tag:` / `dst_tag:` are directional

Prefer these over inventing `(src_* OR dst_*)`.

## Aggregation (`stats:`)

```
stats:<function>(<field>) as <alias> [by <field>]
```

Functions: `count`, `sum`, `avg`, `min`, `max`. `count()` takes no field.
Quote when the expression has spaces:
`stats:"count() as total, avg(value) as average"`.

```
in:devices stats:count() as total by type
in:cpu_metrics time:last_24h stats:avg(usage_percent) as avg_cpu
in:flows time:last_1h stats:sum(bytes_total) as bytes by src_ip sort:bytes:desc
```

Device group-by also accepts `tags.<key>` and `metadata.<key>`. Grouped device
queries default to 20 rows and cap at 100 — set `limit:` when the dimension is
large. Missing JSON keys count as `Unknown`.

## Downsampling (`bucket:`)

For time-series charts:

- `bucket:5m` (suffixes `s|m|h|d`)
- `agg:avg|min|max|sum|count|rate` (`avg` default)
- `value_field:<numeric field>`
- `series:<field>` splits one series per distinct value

```
in:flows time:last_6h bucket:5m agg:sum value_field:bytes_total
```

## Common mistakes

- SQL (`SELECT ... WHERE ...`) — rejected.
- JSON filter objects — rejected.
- Missing `in:` — `queries must include an in:<entity> token`.
- Cross-field `OR` / parentheses groups — invalid.
- Inventing field names — call `get_srql_catalog` with `entity`.
- Passing SRQL in `get_device` `uid` — uid is a bound identifier, not SRQL.
- `/api/mcp` — that path is gone. Tools are `execute_srql` on this server.

`list_devices` and `get_device` are inventory shortcuts. Logs, events, flows,
metrics, and everything else go through `execute_srql`.
