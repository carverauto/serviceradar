# Change: Filter observability (logs, traces, metrics) by OTel service

## Why

GitHub issue #4695. Operators cannot narrow the logs, traces, or metrics panes to
one application. The service is displayed on every row but is not clickable, no
pane has a service control, and the only way to filter is to hand-type a
`service_name:` token into the query bar and already know the exact name. That
does not work for deployments with hundreds or thousands of reporting services.

Nothing lists the services that have reported telemetry. The per-signal rollups
(`logs_severity_stats_5m`, `traces_stats_5m`, `spans_red_1h`,
`otel_metrics_hourly_stats`) each carry a `service_name`, but they are
CNPG-only, they cover different retention windows, and the logs rollup stops
receiving rows once logs are cut over to StarRocks. SRQL cannot list them
either: CNPG `in:logs` offers only `group_uniq_array(service_name)` (unbounded,
no counts), while the StarRocks dialect offers only `count() by service_name`.

The /devices page already has a searchable breakdown modal for device types and
vendors, but it filters an in-memory list in the LiveView process, renders every
match, and replaces the whole query on selection. That fits about 16 device
types; it does not fit thousands of services.

## What Changes

- Add a **service catalog**: `platform.otel_service_catalog`, one row per OTel
  `service.name`, with per-signal last-seen timestamps for logs, traces and
  metrics. EventWriter maintains it as a throttled, best-effort side effect of
  persisting a batch. It works the same whether telemetry lands in CNPG or
  StarRocks. A one-shot worker backfills it from the existing rollups, and a
  daily Oban job prunes entries not seen within the retention window.
- Add an SRQL entity `in:otel_services` over the catalog. It supports
  server-side substring search on `service_name`, a `signal:` filter, sorting,
  a bounded `limit`, and `stats:"count() as total"` for the match count.
- Add a `service_name:` filter to `in:otel_trace_summaries` that matches any
  span's service through `service_set`, backed by a new GIN index.
  `root_service_name:` keeps its root-only meaning.
- Add a **service filter control** to the logs, traces and metrics panes. It
  opens a searchable service-picker modal with server-side, debounced, capped
  search, a match count, multi-select, and a free-text fallback.
- Applying the selection **merges** a `service_name:` token into the pane's
  query and keeps the other filters. The filter carries across tab switches.
  Clicking a service name in a row applies that single-service filter. Stat
  cards scope to the selected services, or visibly say they cannot.

Not included: the device-type modal on /devices stays as it is (the new picker
is built as a reusable component, but migrating /devices is out of scope).
Faceting by `service.namespace` or `deployment.environment` is also out of
scope, and so is any change to monitored service checks (`in:services`, the
`/services` page), which are a different concept.

## Impact

- Affected specs: `observability-signals`, `srql`, `cnpg`
- Affected code:
  - `elixir/serviceradar_core/priv/repo/migrations/**`: the catalog table,
    its trigram and last-seen indexes, and the `service_set` GIN index
  - `elixir/serviceradar_core/lib/serviceradar/observability/`: new Ash
    resource for the catalog, plus the prune and backfill workers
  - `elixir/serviceradar_core/lib/serviceradar/event_writer/processors/{logs,otel_traces,otel_metrics}.ex`
    and a new node-local seen-cache under `event_writer/`
  - `rust/srql/src/parser/entity.rs`, `rust/srql/src/query/otel_services.rs`
    (new), `rust/srql/src/query/trace_summaries.rs`, `rust/srql/src/schema.rs`
  - `elixir/web-ng/lib/serviceradar_web_ng/srql/entity_access.ex`,
    `elixir/web-ng/lib/serviceradar_web_ng_web/srql/catalog.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/log_live/index.ex` and a
    new reusable service-picker component
- Coordination:
  - `refactor-otel-signal-correlation` owns the requirements "Observability
    stat cards reflect stored rollups" and "Rollup stats drill-down filters".
    This change adds its own requirements next to them and does not modify
    those blocks, so archiving either change cannot overwrite the other.
  - `extend-starrocks-to-all-telemetry` tasks 3.1 and 3.2 (OTel traces and
    metrics to the warehouse) do not affect the catalog, because EventWriter
    maintains it on both write paths.
