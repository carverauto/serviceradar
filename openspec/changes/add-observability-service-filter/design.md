## Context

The logs, traces and metrics panes are one LiveView,
`ServiceRadarWebNGWeb.LogLive.Index`. Each tab keeps its SRQL query in `?q=`:
`in:logs`, `in:otel_trace_summaries` (which falls back to `in:traces` when
empty), and `in:otel_metrics` or `in:otel_metric_points` (`mview=points`).
Filters are edited as SRQL tokens, through `strip_filter/2` and
`extract_filter_from_query/2`.

"Service" here means the OTel `service.name` resource attribute, which
EventWriter stamps into `service_name` on every row. It is not a monitored
service check (`in:services`, `service_status`, `/services`). The new entity is
named `otel_services` to keep the two apart.

Service field names per SRQL entity today:

| Entity | Field | Notes |
|---|---|---|
| `logs` | `service_name` | text filter; CNPG, or StarRocks after cutover |
| `otel_traces` / `traces` | `service_name` | per span |
| `otel_trace_summaries` | `root_service_name` only | `service_set text[]` is stored but not filterable |
| `otel_metrics` | `service_name` | `count() by service_name` supported |
| `otel_metric_points` | `service_name` | `count() by service_name` supported |

Reads are routed by `ServiceRadarWebNG.SRQL.query/2` through
`Readers.mode_for/1`. Only `logs` has a warehouse dataset today. OTel traces and
metrics always read CNPG.

## Goals / Non-Goals

- Goals:
  - Pick one or more services from a searchable list on the logs, traces and
    metrics panes, at a cost that does not grow with total service count.
  - Search results come from the server. Nothing loads the full service list
    into the LiveView process.
  - A selection narrows the pane without discarding the other filters.
  - Behave the same with StarRocks enabled or disabled.
- Non-Goals:
  - Migrating the /devices breakdown modal to the new component.
  - Faceting by `service.namespace`, `deployment.environment` or
    `service.version`.
  - A service dependency map, or per-service health scoring.

## Decisions

### D1. A maintained catalog table, not DISTINCT over telemetry

The catalog is `platform.otel_service_catalog`:

| column | type | notes |
|---|---|---|
| `service_name` | `text` PK | non-empty, at most 255 characters |
| `logs_last_seen_at` | `timestamptz` null | |
| `traces_last_seen_at` | `timestamptz` null | |
| `metrics_last_seen_at` | `timestamptz` null | covers `otel_metrics` and `otel_metric_points` |
| `first_seen_at` | `timestamptz` not null | |
| `last_seen_at` | `timestamptz` not null | greatest of the three signals |

Indexes: a GIN trigram index on `service_name` (`platform.gin_trgm_ops`, since
pg_trgm is already installed in `platform`) and a btree on `last_seen_at DESC`.
An Ash resource, `ServiceRadar.Observability.OtelServiceCatalogEntry`, owns the
schema. The migration is generated from it.

Alternatives considered:

- **DISTINCT over the per-signal CAGGs at query time.** These rollups are
  CNPG-only and hold different retention windows (5m buckets versus hourly).
  The logs CAGG stops receiving rows once logs cut over to StarRocks. Every
  keystroke in the modal would scan buckets times services. Rejected.
- **DISTINCT over the raw hypertables.** This is a large scan per keystroke.
  Rejected.
- **An SRQL `group by` on each entity.** CNPG `in:logs` has no group-by, and
  the two dialects already diverge. This fixes neither the cost nor the
  StarRocks gap. Rejected.

### D2. The catalog is control-plane state in CNPG in both modes

The catalog holds one row per service with a few timestamps. It is inventory,
like `device_inventory_type_counts`, not telemetry. It stays in CNPG when
StarRocks is enabled, the same way device inventory does. It holds no counts,
rates or samples, so it does not break the "StarRocks is the only telemetry
store" rule. Telemetry counts for a service still come from the telemetry
store for its signal. The SRQL entity has no warehouse dataset, so
`Readers.dataset_for_entity/1` returns nil for it and it always reads CNPG.

### D3. EventWriter maintains the catalog best-effort, throttled

After a logs, traces or metrics batch persists (to CNPG or StarRocks), the
processor:

1. Takes the distinct non-empty `service_name` values in the batch. Values
   longer than 255 characters are dropped and counted.
2. Drops every `(service_name, signal)` pair that a node-local ETS cache,
   `ServiceRadar.EventWriter.ServiceCatalogCache`, has seen within
   `refresh_interval` (default 60s).
3. Upserts the rest in one statement. On conflict it sets the signal's
   `last_seen_at` column to the greater of the old and new values. A `WHERE`
   clause skips updates that would not advance the timestamp.

A failed catalog upsert is logged and counted (`:telemetry` event
`[:serviceradar, :event_writer, :service_catalog, :upsert_error]`). It never
fails, nacks or retries the telemetry batch: the telemetry is already durable,
and the next batch refreshes the catalog.

Cost: write volume is bounded by roughly services x signals x nodes per
refresh interval, independent of telemetry volume.

The alternative was an Oban job that periodically rebuilds the catalog from
telemetry. That brings back the dependency on the CNPG CAGGs from D1 and adds
up to one job interval of lag. Rejected, except for the one-shot backfill (D6).

### D4. `in:otel_services` SRQL entity

- **Fields:** `service_name`, `signals` (a derived array of the signals with a
  non-null last-seen), `first_seen`, `last_seen`, `logs_last_seen`,
  `traces_last_seen`, `metrics_last_seen`.
- **Filters:**
  - `service_name:`, with the usual SRQL `%` wildcards, compiled to `ILIKE`
    and served by the trigram index. Exact match and list forms work too.
  - `signal:logs|traces|metrics`, which accepts a list and means "has a
    last-seen for any of these".
  - `time:`, applied to the requested signals' last-seen (or to
    `last_seen_at` when there is no `signal:`).
- **Sort:** `service_name` or `last_seen`. The default is `last_seen:desc`.
- **Limit:** default 50, maximum 500.
- **Stats:** `stats:"count() as total"`, for the modal's "showing 50 of N".
- **Access:** gated in `entity_access.ex`.
  - A query with `signal:` requires the matching view permission
    (`observability.logs.view`, `.traces.view` or `.metrics.view`) for every
    signal named.
  - A query without `signal:` requires at least one of them, and the planner
    rewrites it to the signals the caller holds.
  - This way the catalog never shows that a service emits a signal the caller
    cannot open.

### D5. `service_name:` on trace summaries matches the whole trace

A user filtering traces by service expects every trace that touches the
service, not only traces rooted in it.

- `in:otel_trace_summaries service_name:X` compiles to `service_set @>
  ARRAY[X]`. The list form `service_name:(a,b)` compiles to `service_set &&
  ARRAY[...]`, and negation compiles to `NOT (...)`.
- A migration adds `CREATE INDEX CONCURRENTLY ... USING gin (service_set)`
  with `@disable_ddl_transaction`.
- `root_service_name:` keeps its current meaning.
- Wildcards are rejected for this field on this entity, because array
  containment is exact. The picker always sends exact names.

### D6. Backfill and pruning

- **`OtelServiceCatalogBackfillWorker`** is a unique Oban job that is
  idempotent and safe to re-run. It seeds the catalog from
  `logs_severity_stats_5m`, `spans_red_1h` and `otel_metrics_hourly_stats`
  over the retention window, so the picker has content right after upgrade.
  Gaps (for example logs already in StarRocks) fill in from D3 within one
  refresh interval.
- **`OtelServiceCatalogPruneWorker`** runs daily. It deletes rows whose
  `last_seen_at` is older than `observability.service_catalog.retention_days`
  (default 30) and nulls out per-signal columns older than that.
- **Cardinality guard.** An exporter that sends a unique `service.name` per
  process can grow the catalog without bound. The prune worker emits
  `service_catalog.size`. EventWriter stops inserting new names, while still
  refreshing existing ones, once the table passes `max_entries` (default
  50,000), and logs that at warn level. This caps the damage without dropping
  telemetry.

### D7. Service picker UI

- **Component.** `ServiceRadarWebNGWeb.Components.ServicePicker` is a reusable
  function component plus event helpers. It is built on the shared `ui_modal`
  and does not depend on devices or on any one pane.
- **Trigger.** Each pane's controls row (`log_source_filters`,
  `traces_panel_controls`, `metrics_panel_controls`) gains a "Service" button.
  It reads "All services", the one selected name, or "N services".
- **Loading.** Nothing is queried on disconnected mount. Opening the modal
  runs `start_async` for `in:otel_services signal:<tab> sort:last_seen:desc
  limit:50` plus the count query. Typing (debounced 150ms) re-runs both with
  `service_name:%<q>%`. A stale response is dropped by comparing a request
  token.
- **Selection.**
  - Multi-select checkboxes, with a limit of 20 per filter (well under
    SRQL's 200-value list cap).
  - Selected services stay pinned at the top even when the search no longer
    matches them.
  - Keyboard: arrow keys move, Space toggles, Enter applies, Escape cancels.
- **Free-text fallback.** When the search matches nothing, the modal offers
  "Filter by '<typed>' anyway". This covers a catalog that is lagging or
  pruned.
- **Apply.**
  - The page strips any existing `service_name:` token from the pane's query.
    On traces it also strips a `root_service_name:` the picker previously set.
  - It inserts `service_name:"a"` or `service_name:("a","b")`, then resets
    `cursor` and `page` and pushes a patch.
  - Clear removes the token.
  - Every other token (time, severity, source, sort) is kept.
- **Cross-tab carry.** Tab links built by `ObservabilityPaths` carry the
  current service filter into the target tab's default query.
- **Row links.** The service shown on a log, trace or metric row becomes a
  patch link that applies that single-service filter.
- **Stat cards.** With a service filter active, each card passes the
  selection to `ServiceRadarWebNGWeb.Stats` (which already accepts
  `service_name:`). If a card's backing rollup cannot be narrowed that way,
  the card shows an explicit "all services" badge. It does not silently show
  global numbers under a filtered list. The traces "services" card shows the
  catalog count for the window, replacing the hardcoded `service_count: 0`.
- **Authorization.** Every `handle_event` for the picker re-checks the pane's
  view permission.

## Risks / Trade-offs

- **High-cardinality `service.name`.** Handled by the D6 cap and metric. The
  catalog can then be incomplete for new names, which the free-text fallback
  covers.
- **Catalog lag of up to `refresh_interval` per node.** This is acceptable for
  a picker, and the fallback covers it.
- **GIN index build on a large `otel_trace_summaries`.** It is built
  `CONCURRENTLY`, so it does not block writes. It needs disk headroom on
  demo-sized databases.
- **Overlap with `refactor-otel-signal-correlation`.** That change owns the
  card and drill-down requirements. This change adds separate requirements and
  does not modify them. If it lands first, the stat-card task here reduces to
  passing the service selection through.

## Migration Plan

1. Deploy the migrations (catalog table and indexes, `service_set` GIN index).
2. Deploy core with the EventWriter upserts. The backfill job enqueues once.
3. Deploy SRQL with `otel_services` and the trace-summary filter.
4. Deploy web-ng with the picker.

Rollback: web-ng and SRQL roll back independently. The table and indexes are
additive, and the EventWriter upsert is best-effort, so an older core ignores
the table.

## Open Questions

- Should the picker default sort be recency (`last_seen:desc`, proposed) or
  alphabetical? Recency surfaces active services first when there are
  thousands.
