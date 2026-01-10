# ServiceRadar Query Language (SRQL) - Language Reference

## Overview

ServiceRadar Query Language (SRQL) now uses a key:value syntax that is parsed and executed by the Rust-based SRQL service (`rust/srql`). The engine plans queries against our OCSF-aligned streaming schema defined in `pkg/db/migrations`, translates them to CNPG SQL via Diesel, and returns consistently shaped results. SRQL keeps its readable style while gaining better alignment with the Open Cybersecurity Schema Framework (OCSF) entities that underpin ServiceRadar.

Use SRQL to:
- Select one or more OCSF data domains with `in:<entity>`
- Filter using key:value pairs and nested attribute groups
- Control result shape with sorting, limiting, aggregation statistics, and windowing
- Switch between point-in-time results and streaming updates

## Target Entities and OCSF Alignment

Target data with the `in:` selector. Each logical entity routes to one or more OCSF tables or streams introduced in the `00000000000002_*` through `00000000000005_*` migrations.

| SRQL Entity | Description | Primary OCSF Source |
|-------------|-------------|---------------------|
| `in:devices` | Device inventory and current state (includes discovery metadata and observables) | `ocsf_device_inventory`, `ocsf_devices_current` |
| `in:activity` | Normalized activity & network telemetry. Alias for `events` and maps to connection/flow classes. | `ocsf_network_activity`, `ocsf_system_activity` |
| `in:flows` | Flow-level telemetry aligned to OCSF network activity class 4001 | `ocsf_network_activity` |
| `in:connections` | Connection state and summaries with endpoint metadata | `connections`, `ocsf_network_activity` |
| `in:services` | Observed network/application services and their availability | `services` materialized view |
| `in:interfaces` | Discovered interfaces with OCSF endpoint metadata | `discovered_interfaces` |
| `in:logs` | Application and system logs normalized to OCSF logging classes | `logs`, `ocsf_system_activity` |
| `in:gateways` | Gateway/agent operational telemetry | `gateways` |
| `in:cpu_metrics` / `in:disk_metrics` / `in:memory_metrics` / `in:process_metrics` / `in:snmp_metrics` | Time-series metrics aligned with OCSF telemetry categories | `cpu_metrics`, `disk_metrics`, `memory_metrics`, `process_metrics`, `timeseries_metrics` |
| `in:otel_traces` | OpenTelemetry spans & summaries | `otel_trace_summaries_final`, `otel_spans_enriched` |

`in:` accepts comma-separated targets (e.g. `in:devices,services`). SRQL resolves friendly field names to the correct OCSF column names via the Diesel query builders in `rust/srql/src/query`; for example `device.os.name` maps to `device_os_name` and `boundary` is normalized to `partition`.

The migrations in `00000000000003_ocsf_entity_state_streams.up.sql` and `00000000000005_ocsf_materialized_views.up.sql` also provision current-state streams for users, vulnerabilities, and other OCSF classes. As those entities are surfaced through SRQL aliases they inherit the same key:value syntax described below—no query changes are required beyond swapping the `in:` target.

## Filters and Field References

### Key:Value Filters
- Basic comparisons use `field:value`, e.g. `hostname:%cam%` or `severity_id:2`.
- Values are case-sensitive unless the underlying column is normalized. Use quotes for values with spaces: `device.location:"Building A"`.
- SRQL maps lists with commas to SQL `IN`/`NOT IN`: `device_type_id:(1,7)`.

### Range Queries
- Use standard comparison operators for numeric fields: `usage_percent:>80`, `latency_ms:>=500`.
- Supported operators: `>`, `>=`, `<`, `<=`.
- Combine multiple filters for ranges: `usage_percent:>80 usage_percent:<90`.

### Nested Attributes
Wrap a nested group in parentheses to drill into OCSF objects:
```
in:activity connection:(src_endpoint_ip:10.0.0.% dst_endpoint_port:(22,2222))
```
Nested keys concatenate with dots internally (`connection.src_endpoint_ip`).

### Arrays and Observables
- Repeating the same key expresses “contains all” semantics for arrays:
  `discovery_sources:(sweep) discovery_sources:(armis)`.
- Use observable shortcuts created in the migrations: `observable:ip` scans across `observables_ip` collections. Combine with `value:` to match against a specific observable value.

### Negation and Wildcards
- Prefix a key with `!` to invert it: `!device.status:deleted`, `!hostname:%test%`.
- `%` acts as a wildcard for string comparisons and emits `LIKE`/`NOT LIKE` SQL as appropriate.

## Time Scoping

Control temporal filters with `time:` or `timeFrame:` keys.
- Relative windows: `time:last_24h`, `time:last_7d`, `time:last_30m`.
- Human phrases convert automatically: `timeFrame:"7 Days"` → `time:last_7d`.
- Absolute ranges: `time:[2024-06-01T00:00:00Z,2024-06-02T00:00:00Z]`. Leave one side blank to create open-ended ranges.
- Shortcuts `time:today` and `time:yesterday` apply date equality on the entity’s timestamp field (see `entity_mapping.ml`).

If no time filter is supplied, the engine injects the default window configured by the API (commonly the last 24 hours).

## Sorting, Limiting, and Result Shape

- `limit:<n>` caps the number of rows returned.
- `sort:field[:direction]` applies ordering. Specify multiple sort keys separated by commas: `sort:time:desc,traffic_bytes_out`.
- `stream:true` or `mode:stream` returns a streaming cursor when the backend supports it.

## Aggregations, Windows, and Having

SRQL supports lightweight analytics without writing raw SQL:
- `stats:"count() by device.type_id"` emits `SELECT count() ... GROUP BY device_type_id`.
- `window:5m` buckets results when paired with `stats` to create tumbling window aggregations.
- `having:"count()>10"` filters aggregated results after grouping.

Use these constructs together:
```
in:activity time:last_24h stats:"count() as total_flows by connection.src_endpoint_ip" sort:total_flows:desc having:"total_flows>100" limit:20
```
The planner converts aggregations into valid CNPG SQL, handling `count_distinct`, percentile helpers (`p95(bytes)`), and alias propagation.

## Streaming Queries

Set `stream:true` to subscribe to entity streams such as `ocsf_network_activity`. Combine with `window` for sliding analytics or leave `window` unset for raw event feed semantics. `stats` + `stream:true` produces continuously updating grouped results with the backend’s incremental materialized view engine.

## Example Queries

- Devices discovered by multiple sources in the past week:
  `in:devices discovery_sources:(sweep) discovery_sources:(armis) time:last_7d sort:last_seen:desc`

- High-volume web activity from a private network block:
  `in:activity time:last_24h src_endpoint_ip:10.0.% dst_endpoint_port:(80,443) stats:"sum(traffic_bytes_out) as bytes_out by src_endpoint_ip" window:1h sort:bytes_out:desc having:"bytes_out>100000000"`

- Detect devices with elevated CPU usage during the last hour:
  `in:cpu_metrics time:last_1h stats:"avg(usage_percent) as avg_cpu by device_id" having:"avg_cpu>85" sort:avg_cpu:desc`

- Track SSH or SFTP services discovered in the last two weeks:
  `in:services service_type:(ssh,sftp) timeFrame:"14 Days" sort:timestamp:desc`

- OpenTelemetry traces exceeding latency SLO:
  `in:otel_traces service.name:"serviceradar-agent-gateway" stats:"p95(duration_ms) as p95_latency by service.name" window:5m having:"p95_latency>1000"`

## Best Practices

- Anchor every query with `in:` and an explicit `time` window to constrain scans.
- Prefer SRQL field aliases (e.g. `device.os.name`, `connection.dst_endpoint_ip`) over raw column names; the engine keeps them aligned with the OCSF migrations.
- Use repeated keys for array containment checks and comma lists for scalar `IN` comparisons.
- Inspect new OCSF columns in `pkg/db/migrations` before adding filters so names stay consistent with upstream schema revisions.
- Validate complex queries with the `srql.validate` MCP tool or the SRQL CLI under `rust/srql`.

## Supported Filter Fields by Entity

Each entity supports a specific set of filter fields. Using an unsupported field will return an error indicating the invalid field name.

### devices

| Field | Description |
|-------|-------------|
| `device_id` | Unique device identifier |
| `hostname` | Device hostname (supports wildcards) |
| `ip` | IP address (supports wildcards) |
| `mac` | MAC address (supports wildcards) |
| `gateway_id` | Associated gateway ID |
| `agent_id` | Associated agent ID |
| `is_available` | Availability status (`true`/`false`) |
| `device_type` | Type of device |
| `service_type` | Type of service |
| `service_status` | Service status |
| `discovery_sources` | Sources that discovered this device (array containment) |

### ocsf_events

| Field | Description |
|-------|-------------|
| `id` | Event identifier |
| `time` | Event timestamp |
| `class_uid` | OCSF class UID |
| `category_uid` | OCSF category UID |
| `type_uid` | OCSF type UID |
| `activity_id` | Activity ID |
| `activity_name` | Activity name |
| `severity_id` | Severity ID |
| `severity` | Severity label |
| `message` | Event message |
| `log_name` | Log name or subject |
| `log_provider` | Log provider |
| `tenant_id` | Tenant identifier |

### logs

| Field | Aliases | Description |
|-------|---------|-------------|
| `trace_id` | | OpenTelemetry trace ID |
| `span_id` | | OpenTelemetry span ID |
| `service_name` | | Name of the service |
| `service_version` | | Service version |
| `service_instance` | | Service instance identifier |
| `scope_name` | | Instrumentation scope name |
| `scope_version` | | Instrumentation scope version |
| `severity_text` | `severity`, `level` | Text representation of severity |
| `body` | | Log message body |
| `severity_number` | | Numeric severity level |

### traces (otel_traces)

| Field | Aliases | Description |
|-------|---------|-------------|
| `trace_id` | | OpenTelemetry trace ID |
| `span_id` | | Span identifier |
| `parent_span_id` | | Parent span identifier |
| `service_name` | | Name of the service |
| `service_version` | | Service version |
| `service_instance` | | Service instance identifier |
| `scope_name` | | Instrumentation scope name |
| `scope_version` | | Instrumentation scope version |
| `name` | `span_name` | Span name |
| `status_message` | | Status message |
| `status_code` | | Numeric status code |
| `kind` | `span_kind` | Span kind (integer) |

### services

| Field | Aliases | Description |
|-------|---------|-------------|
| `service_name` | `name` | Name of the service |
| `service_type` | `type` | Type of service |
| `gateway_id` | | Associated gateway ID |
| `agent_id` | | Associated agent ID |
| `partition` | | Partition identifier |
| `message` | | Status message |
| `available` | | Availability status (`true`/`false`) |

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

### otel_metrics

| Field | Aliases | Description |
|-------|---------|-------------|
| `trace_id` | | OpenTelemetry trace ID |
| `span_id` | | Span identifier |
| `service_name` | `service` | Name of the service |
| `span_name` | | Span name |
| `span_kind` | | Span kind |
| `metric_type` | `type` | Type of metric |
| `component` | | Component name |
| `level` | | Level |
| `http_method` | | HTTP method |
| `http_route` | | HTTP route |
| `http_status_code` | | HTTP status code |
| `grpc_service` | | gRPC service name |
| `grpc_method` | | gRPC method name |
| `grpc_status_code` | | gRPC status code |
| `is_slow` | | Slow request flag (`true`/`false`) |

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

### timeseries_metrics

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

### interfaces

| Field | Aliases | Description |
|-------|---------|-------------|
| `device_id` | | Device identifier |
| `device_ip` | `ip` | Device IP address |
| `gateway_id` | | Associated gateway ID |
| `agent_id` | | Associated agent ID |
| `if_name` | | Interface name |
| `if_descr` | `description` | Interface description |
| `if_alias` | | Interface alias |
| `if_phys_address` | `mac` | Physical (MAC) address |
| `if_admin_status` | | Administrative status |
| `if_oper_status` | `status` | Operational status |
| `if_speed` | `speed` | Interface speed |
| `ip_addresses` | `ip_address` | IP addresses assigned to interface |

## Error Handling

Common issues and suggested fixes:
- **Unsupported filter field** – The field name is not valid for the specified entity. Check the [Supported Filter Fields](#supported-filter-fields-by-entity) section above for valid fields.
- **Unknown field** – The key cannot be mapped via `entity_mapping`. Check the OCSF migration files or use the CLI's schema inspection.
- **Missing target entity** – Add `in:<entity>` to specify which OCSF domain to query.
- **Invalid time range** – Ensure `time:` ranges are well-formed (`last_<number><unit>` or `[start,end]`).
- **Aggregation conflicts** – When using `stats`, ensure grouped fields appear inside the `by` clause and reference aliases correctly in `having`.
- **Unsupported negation form** – Negation applies to the key (`!key:value`) rather than the value (`key:!value`).

SRQL is designed to evolve with the OCSF schema. As additional migrations add classes or fields, extend your queries by following the same key:value conventions and the alignment guidance above.
