## 1. Schema (serviceradar_core)

- [ ] 1.1 Add Ash resource `ServiceRadar.Observability.OtelServiceCatalogEntry`
      (table `otel_service_catalog`, `platform` schema), and generate its
      migration with the trigram GIN index on `service_name` and the btree
      index on `last_seen_at DESC`.
- [ ] 1.2 Add a migration for the `service_set` GIN index on
      `platform.otel_trace_summaries` (`@disable_ddl_transaction`,
      `concurrently: true`).
- [ ] 1.3 Add both new migrations to the baseline or migration-gate
      inventories the tree requires. Run `mix serviceradar.db.migrate`
      against a srql-fixtures scratch DB.

## 2. Catalog maintenance (EventWriter)

- [ ] 2.1 Add `ServiceRadar.EventWriter.ServiceCatalogCache`, a node-local ETS
      seen-cache keyed by `(service_name, signal)` with `refresh_interval`
      (default 60s), supervised under the EventWriter supervisor.
- [ ] 2.2 Add a batched upsert: advance the signal's last-seen with
      `GREATEST`, skip non-advancing updates with a `WHERE`, and drop empty and
      overlong names.
- [ ] 2.3 Call it after a successful persist in the `logs`, `otel_traces` and
      `otel_metrics` processors (including metric points), on both the CNPG
      and StarRocks destinations. Make sure a failure only logs and emits
      `[:serviceradar, :event_writer, :service_catalog, :upsert_error]`.
- [ ] 2.4 Tests: a new service is recorded; a repeated batch inside the
      interval issues no write; an upsert failure leaves the batch acked; empty
      and overlong names are ignored.

## 3. Backfill and prune jobs

- [ ] 3.1 `OtelServiceCatalogBackfillWorker`: a unique, idempotent job that
      seeds from `logs_severity_stats_5m`, `spans_red_1h` and
      `otel_metrics_hourly_stats` over the retention window. Enqueue it once
      after migration.
- [ ] 3.2 `OtelServiceCatalogPruneWorker`: a daily job that deletes entries
      past `retention_days` (default 30), and nulls stale per-signal columns.
- [ ] 3.3 Tests for both workers, and `INTEGRATION_SOURCE_DISPOSITIONS.tsv`
      rows for every new test file.

## 4. SRQL (rust/srql)

- [ ] 4.1 Add the `otel_services` entity (parser alias, schema, model, query
      module): filters `service_name` / `signal` / `time`, sort
      `service_name` / `last_seen`, limit default 50 and maximum 500, and
      `stats:"count() as total"`. The planner is the single parser of
      `signal:`: it intersects the values with the trusted permitted-signal
      parameter, and rejects a repeated or negated `signal:`, an empty
      intersection and a missing set. `signals`, `last_seen`, `time:` and the
      default ordering derive only from the resulting signals; other signals'
      per-signal fields are null.
- [ ] 4.2 Add a `service_name` filter on `otel_trace_summaries`: `@>` for a
      single value, `&&` for a list, `NOT` for negation, and an
      invalid-request error for wildcards.
- [ ] 4.3 Confirm `Readers.dataset_for_entity("otel_services")` returns nil
      (CNPG always).
- [ ] 4.4 Rust tests for the generated SQL of each filter, sort, limit clamp
      and stats path, plus a guard that `in:services` is unchanged. Run
      `cargo fmt` and `cargo clippy`.

## 5. Access control and catalog metadata (web-ng)

- [ ] 5.1 `entity_access.ex`: add an any-of permission mapping for
      `otel_services` (logs, traces or metrics view). `authorize/3` rejects a
      caller holding none and returns the permitted signal set with `:ok`. It
      does not edit the query string. Update every caller (`srql.ex` `query`
      and `query_arrow`, `api/access.ex`) to pass that set to SRQL as a
      trusted request parameter. Land this with or before the SRQL entity
      (task 4.1).
- [ ] 5.2 `srql/catalog.ex`: add the `otel_services` entity, and add
      `service_name` to the `otel_trace_summaries` fields.
- [ ] 5.3 Tests for authorized, unauthorized and narrowed queries through all
      three caller paths, including a logs-only caller that must not see trace
      or metric activity in `signals`, `last_seen` or ordering. One scenario
      per form: `signal:(logs,traces)`, a repeated `signal:`, `!signal:logs`,
      `SIGNAL:traces`, a nil scope with `optional_scope: true`, and a missing
      permitted set.

## 6. Service picker UI (web-ng)

- [ ] 6.1 Build the reusable `ServicePicker` component on `ui_modal`: search
      input (150ms debounce, autofocus), capped result list, "N of M" count,
      multi-select (at most 20) with selected entries pinned, free-text
      fallback, keyboard navigation, and Apply / Clear / Cancel.
- [ ] 6.2 In `LogLive.Index`, add the "Service" trigger in the logs, traces
      and metrics controls. Open the modal with `start_async` for the list and
      count queries, and drop stale responses by request token. Run no query
      during disconnected mount.
- [ ] 6.3 Apply and clear: strip and insert the `service_name:` token so
      other tokens are kept, reset `cursor` / `page`, and `push_patch`.
- [ ] 6.4 Carry the service filter through `ObservabilityPaths` tab links.
      Make row service names patch links.
- [ ] 6.5 Stat cards: change `Stats` and `Stats.Query` to accept a list of
      service names and map it to each rollup's list filter
      (`logs_severity_result`, `traces_summary`, `metrics_summary`). Show the
      "all services" badge where a rollup cannot take a list. Replace the
      hardcoded traces `service_count: 0` with the catalog count.
- [ ] 6.6 Re-check the pane permission in every picker `handle_event`.
- [ ] 6.7 LiveView tests: server-side search returns at most 50 of many; the
      picker is signal-scoped; filters are kept on apply; a selection change
      replaces the previous one; the filter carries across tabs; row click;
      unauthorized event rejected; no query on disconnected mount.

## 7. Verification

- [ ] 7.1 `openspec validate add-observability-service-filter --strict`
- [ ] 7.2 `make test` (the full Bazel unit suite, including the Elixir
      shards).
- [ ] 7.3 Run the new migrations and DB-backed tests against a srql-fixtures
      scratch DB (not the shared template).
- [ ] 7.4 Local web-ng + Playwright check with a synthetic catalog of more
      than 1,000 invented service names: search latency, cap, apply, tab
      carry.
