## 1. Parity gate and fail-closed dialect

- [ ] 1.1 Land the pending dialect fixes found by the first cutover: tag-split series (`core_id`, `tags.<key>`) and newest-N `sort:desc limit` (PR #4526). Counter `rate`/`rate_sum` is already merged (PR #4522).
- [ ] 1.2 Land flows parity: `tcp_flags_label`, `duration_bucket`, `exporter_name` (with the reader grant), `src_cidr`/`dst_cidr` filters.
- [x] 1.3 Make the StarRocks dialect fail closed: a plan feature it does not consume (`rollup_stats`, `other`, unknown field, ignored `sort`) is an `InvalidRequest`, with a test per feature.
  - `refuse_unimplemented_features` (`rust/srql/src/query/starrocks.rs`) runs before compilation and returns `InvalidRequest` for a `rollup_stats` kind this dialect does not implement (named in the message), a rollup combined with `stats:`/`bucket:`, and `other:true` outside a grouped flow/metric stats query; an unknown field is refused by `column_sql` as `unsupported StarRocks field`. A caller's `sort` is compiled rather than dropped, including on the profile route. One test per refusal.
- [x] 1.4 Add a repository target that seeds CNPG and StarRocks with the same synthetic rows and diffs result sets for a list of query shapes; synthetic data only.
  - `//integration_tests/srql_parity:parity_test` (tagged `integration_test`, `manual`, `external`, `no-remote-cache`, `requires-network`; gated by `requires_shared_fixture()`). It creates a throwaway `srql_parity_<stamp>_<pid>` database on the srql-fixtures CNPG and on a StarRocks FE, builds the CNPG side from the committed baseline plus the post-baseline columns and continuous aggregates, the StarRocks side from `priv/starrocks/*.sql` as `SchemaMigrator` applies it, seeds both from one synthetic generator (metrics, flows, logs, events, MTR), compiles every inventory query through `srql::query::translate_request` in both modes, and diffs the normalised rows; both databases are dropped at the end and stale ones swept. Credentials are read from the environment at run time (`--test_env` passthrough). The first run found the chart `series` column differing (`'all'`/NULL on StarRocks where CNPG returns NULL/`''`); fixed in the dialect (`downsample_series_sql`). A mutation check (rate as SUM of counters; loss as mean of per-hop `loss_pct`) fails the counter-rate and MTR loss entries.
- [ ] 1.5 Derive the per-dataset query-shape inventory from the code and check it into the harness; a test fails when a new `in:<entity>` chart query appears without an inventory entry.
  - Done: `integration_tests/srql_parity/inventory.json`, and `//integration_tests/srql_parity:srql_parity_test` (unit tier) loads the checked-in dashboard and dashboard-package JSON as data, reads every panel's `srql_query`/`query`, and fails on a chart query on a warehouse-served entity that no entry's shape covers; each dashboard root must yield at least one warehouse query, so a root missing from the runfiles fails loudly.
  - Done: chart queries the product assembles in Elixir are guarded by `elixir/web-ng/test/phoenix/srql/warehouse_query_inventory_test.exs` (web-ng database-free unit tier, `//elixir/web-ng:unit_tests_phoenix_other`). It drives the product's query builders through their public functions -- loaders are handed a capturing SRQL module or runner, pure builders are called -- and fails, printing the query, on any produced chart query on a warehouse-served entity (`Readers.dataset_for_entity/1`) with no inventory entry of the same shape. It reads `inventory.json` as declared test data. The shape normalization is defined in `src/shape.rs` and ported to Elixir (`test/support/srql_parity_shape.ex`); `shape_examples.json` pins both. Builders that were private now route through public functions the product itself calls: `LogLive.NetflowPanelQueries` (every NetFlow panel of the observability page, enumerable through `panels/0`), `EventLive.AnomalyMetricQueries.variants/5`, `DashboardLive.Data.NetflowSummary.srql_query/1`, `Flows.AttributedLive.summary_query/1`, `ObservabilityHealthLive.Index.health_query/0`, and `NetflowSecurityRefreshWorker.port_scan_query/2` / `port_anomaly_queries/3`. The Sankey is driven over every prefix and every dimension `NetflowLive.Visualize.Config` offers.
  - Open: builders outside the driven set are not guarded -- notably the NetFlow visualize page's chart data (`NetflowLive.Visualize.ChartData`, overlays), which chooses series fields at run time. Row listings are out of scope, as for the dashboard definitions.
- [ ] 1.6 Record each accepted deviation (approximate percentiles, sample-weighted vs mean-of-means average, inclusive vs exclusive upper bound) with its reason; align the ones that are accidents.
  - Recorded in `inventory.json` `deviations`, each with the entry that proves it still holds (an `expect: mismatch` entry pins the rows each backend returns in `recorded`, so a new difference on the same query fails; the `recorded` blocks are captured from live runs, and inventory validation in the unit tier rejects an `expect: mismatch` entry without one): no counter ceiling / 2^64 wrap arm in the warehouse, `'none'` vs `''` TCP-flag label, directional fallback for flows without totals, the CNPG events `count` column name, and CNPG refusing flow `by partition`. Open: `by app` is a different classifier on each backend (StarRocks reads the ingest-time ServicePorts label and never applies `netflow_app_classification_rules`), recorded as a `defect`; `src_cidr:<n>`/`dst_cidr:<n>` groups by subnet on neither backend (CNPG keeps the host bits, StarRocks cuts at the dots and breaks on IPv6), recorded as a `defect`; `direction` and the country groups join the `cnpg_platform` catalog on StarRocks and are compiled but not executed (`starrocks_joins_catalog`), so they are not parity-checked; no approximate-percentile shape is inventoried yet.
  - Aligned (both were accidents, so their deviations are gone and the entries that proved them are exact comparisons): the CNPG metric and event builders now close the window half-open (`< end`) like the StarRocks dialect and the CNPG flow stats and MTR builders -- the raw metric list, raw metric stats and raw bucketed read (`timeseries_metrics.rs`, the shared `downsample/sql.rs` raw path) the events list/count (`events/query.rs`), and the logs list and stats (`logs/mod.rs`, `logs/stats.rs`; the severity rollup was already half-open); `metrics.edge.upper_bound_raw_route`, and `logs.edge.upper_bound` over new edge-window log rows. A multi-hour bucket averaged from `timeseries_metrics_hourly` is now weighted by `sample_count` (`SUM(avg_value * sample_count) / SUM(sample_count)`, the raw-row average StarRocks computes) instead of the mean of the hourly means; `metrics.icmp.avg_2h_buckets_long_window`. Not yet confirmed by a live two-backend run.
- [x] 1.7 `other:true` top-N with an "Other" tail for flows and metrics.
  - `other_rollup_sql` mirrors CNPG's `build_other_rollup_sql`: groups are ranked by the query's own sort with every group key as an ascending tie-break, the top `limit` are kept, and the remainder folds into one row with NULL group keys and `__other__` set, absent when nothing is left over. Only `sum`/`count` re-aggregate by summing, so only those are accepted, and `offset` is not part of the cut on either backend. Both engines returned the same rows in the same order in the parity run recorded in `k8s/starrocks/README.md`.

## 2. Logs and events: warehouse readers to parity

- [ ] 2.1 Day-partitioned async MVs for log severity counts and event anomaly-finding counts; `rollup_stats:severity` and `rollup_stats:anomaly_findings` compile to them, with `RollupFreshness` fallback to raw.
- [x] 2.2 Logs filter vocabulary on StarRocks: `severity`, `level`, `severity_match`, `device_id`.
  - `dataset_filter_sql` compiles `severity_text`/`severity`/`level` to the bucket the cards group by (recognized text authoritative, the number speaking only for a row whose text is absent or unrecognized) and `device_id`/`uid` to the device identity arms. `severity_match:any` is not a plain OR of the two lists: `filter_predicates` folds it, the text filter and the number filter into the one predicate `query/logs/filters.rs` writes for CNPG. A log field with no warehouse column stays refused.
- [x] 2.3 Events filter vocabulary on StarRocks: `log_level`, `event_type`, `host`, `device_id`, `finding_uid`.
  - `log_level` is an ordinary column, added by `priv/starrocks/0018_events_documents.sql` along with the `metadata`/`unmapped`/`device`/`observables` documents. `event_type`, `finding_uid` and `host_id`/`hostname` read the same document paths CNPG reads, via `get_json_string`; `device_id` compiles to CNPG's canonical, alias and document-scan arms in both polarities. The three remaining differences from CNPG, and the row-shape decoding that makes a warehouse event row indistinguishable from a CNPG one, are recorded in `k8s/starrocks/README.md`.
- [ ] 2.4 Route the direct CNPG readers through `Readers`: dashboard throughput sparklines, device Flows-tab presence probes, and any logs/events stat card that bypasses SRQL.
- [ ] 2.5 Measure log search on the deployed profile: which index types shared-data supports, and latency of a substring search over 1, 30 and 365 days; document the supported behaviour.
- [ ] 2.6 Run the parity harness for the `logs` and `events` warehouse readers; ship each reader only after it passes; verify cards and charts against ground truth after the rollout completes.

## 3. Extend the warehouse to the remaining telemetry

- [ ] 3.1 OTel metric points and metric definitions: table, EventWriter destination, SRQL dataset routing, parity.
  - [x] 3.1.1 Warehouse DDL `priv/starrocks/0021_otel_metrics.sql`: `otel_metrics` (span-derived
    samples) and `otel_metric_points` (OTLP sum/gauge/histogram points) with every CNPG column
    under the same name, a key `id` derived from the rest of the CNPG primary key, day partitions
    and retention. A metric's definition (type, unit, temporality, monotonicity) travels on each
    point, as on CNPG; there is no separate definitions table to move.
    - Load datasets `:otel_metrics` and `:otel_metric_points`, one retention dataset `otel`
      (default 365 days, `SERVICERADAR_STARROCKS_RETENTION_DAYS_OTEL`, Helm
      `retentionDays.otel`, Compose `STARROCKS_RETENTION_DAYS_OTEL`) applied to both tables. Not
      in the shadow/cutover dataset lists.
  - [x] 3.1.2 EventWriter `OtelMetrics.store/3` writes samples then points to the warehouse only
    when StarRocks is enabled (`Destination.enabled?/0`), to CNPG only otherwise. A failed load
    fails the batch, JetStream redelivers, and the primary-key tables upsert the same keys.
  - [x] 3.1.3 SRQL `in:otel_metrics`/`in:metrics` and `in:otel_metric_points`/`in:metric_points`
    have a StarRocks dialect (`rust/srql/src/query/starrocks/otel_metrics.rs`), and
    `Readers.mode_for/1` sends them to it whenever StarRocks is enabled, to CNPG otherwise. It
    uses the CNPG builders' own `count() as <alias> [by <field>]` parse and sort-field lists, so
    both backends accept the same queries; `bucket:`, `rollup_stats:` and `other:true` are refused
    on both. Warehouse rows carry the CNPG select list, with `is_slow`/`is_monotonic` decoded to
    booleans in `EventDocuments`.
    - CNPG fixes so the backends agree: `sort:duration_ms` was dropped, so the Analytics slowest
      spans came back unsorted; an unknown row sort field is now refused rather than dropped; the
      stats alias was written into a SQL string literal unvalidated and must now be an
      identifier; `rollup_stats:`/`other:` were ignored.
    - LogLive `load_sparklines` is removed, not ported: it read `otel_metrics.metric_name` and
      `value`, which that table does not have, for `gauge`/`counter` rows, which span samples
      never are, so it could never return data.
  - [ ] 3.1.4 Run the parity database tier (`//integration_tests/srql_parity:parity_test`) for the
    `otel.*` inventory entries against the OTel fixture (`src/fixture/otel.rs`), then verify the
    logs page metrics tab, OTLP view, metric detail and Analytics slowest spans on a deployment
    after the rollout completes.
  - [ ] 3.1.5 JSON:API `/otel_metrics` and `/otel_metric_points` still read CNPG (as `/api/v2/logs`
    does for logs); route or retire them with the other JSON:API telemetry readers in 5.4.
- [ ] 3.2 OTel traces/spans with RED and summary rollups as MVs; trace-by-id lookup.
- [ ] 3.3 Sysmon CPU/memory/disk/process: table(s), destination, routing, hourly rollups.
- [ ] 3.4 MTR traces and hops (spec: "MTR traces and hops reach the warehouse through JetStream").
  Scalar MTR metrics already travel on `metrics.mtr` (gateway `MtrMetricsPublisher` -> EventWriter
  `Metrics`); full traces and hops do not: scheduled results go gateway -> core
  `ResultsRouter.handle_mtr_results/1`, on-demand and bulk results go through
  `AgentCommands.StatusHandler.ingest_mtr_result/3` and `ingest_bulk_target_traces/3`, and all of
  them call `MtrMetricsIngestor.ingest/2`, which writes CNPG through Ash. Ad-hoc scan results
  already arrive on JetStream (`scans.results.>` -> `AdhocScan`), but `AdhocScan.ingest_mtr_traces`
  persists them through the same `MtrMetricsIngestor` into CNPG, so all four paths write CNPG
  directly today.
  - [x] 3.4.1 JetStream subject and stream for MTR trace results; core publishes on the three
    core-side paths (scheduled, on-demand, bulk) instead of calling the ingestor. Add it to the
    EventWriter default streams.
    - `mtr.results.ingest`, stream `mtr_results` (`MTR_RESULTS`), one message per trace published
      with a JetStream PubAck by `MtrResultPublisher`; core's NATS publish allow-list includes it.
  - [x] 3.4.2 EventWriter `Mtr` processor: normalizes and enriches as `MtrMetricsIngestor` does
    today, persists traces and hops (warehouse when StarRocks is enabled, CNPG otherwise), then
    runs `MtrGraph.project_traces` and `MtrPubSub.broadcast_ingest` so live pages keep updating.
    The processor is the single owner; core keeps no direct MTR write.
    - CNPG half: `Processors.Mtr` stores through `MtrMetricsIngestor` with a per-trace
      `trace_uuid` and `skip_existing`, so redelivery is a no-op, then announces on `MtrPubSub`.
    - Warehouse half: `Processors.Mtr.store/3` branches on `analytics.starrocks.enabled` alone
      (`Destination.enabled?/0`; no shadow or cutover list). Enabled, it builds the rows
      `MtrMetricsIngestor.rows/2` produces -- the same rows the CNPG insert writes -- per
      message, drops a permanently bad message on its own, then issues one Stream Load for the
      batch's traces and one for its hops (`Destination.persist_warehouse`, traces first). It
      writes nothing to CNPG and projects the graph and announces only after both loads succeed;
      a failed load fails the batch as a transient error, so JetStream redelivers and the
      primary-key tables upsert identical keys. Hop ids are `MtrMetricsIngestor.hop_id(trace_id, index)`,
      so a redelivered trace upserts the same keys.
  - [x] 3.4.3 `AdhocScan` hands MTR traces to the same warehouse-aware MTR persistence the `Mtr`
    processor uses instead of calling `MtrMetricsIngestor`, so scheduled, on-demand, bulk and
    ad-hoc traces share one owner and none writes CNPG when StarRocks is enabled.
    - `AdhocScan` calls `Processors.Mtr.persist_all/2`, with the same permanent-vs-transient
      handling; a transient MTR failure now fails the batch. Row ids and trace ids are derived
      from the message bytes, so the redelivery rewrites the same keys. `AdhocScanResultHandler`
      publishes each row with `JetStreamPublish` under a short PubAck timeout and logs a row no
      stream acknowledged.
  - [x] 3.4.4 Warehouse DDL `priv/starrocks/0019_mtr.sql`: `mtr_traces` and `mtr_hops` with every
    CNPG column, including probed/last-responding depth, TCP port, handshake fields and hop reply
    counters; day partitions and retention. Register the dataset in `Env`, `Destination @tables`,
    `Rows.encode_row/2`, `Retention @tables`, Helm `retentionDays` and the Compose env.
    - Two load datasets, `:mtr_traces` and `:mtr_hops` (one per table, as `Destination` and
      `Rows` are per table), and one retention dataset, `mtr` (default 30 days, the MtrSettings
      history default), applied to both tables. MTR is not added to the shadow/cutover dataset
      lists in `Env`, since it does not use them. The Settings -> MTR retention still governs
      only the CNPG tables.
  - [ ] 3.4.5 Hop rollups as async MVs aggregating loss with `loss_ratio(sent, received)` and
    latency with `wavg(avg_us, received)`. `mtr_hops.asn` is GeoLite2-only and NULL for every
    internal hop and private AS, so an AS-level rollup is not presented as fleet-wide.
  - [ ] 3.4.6 Warehouse readers for `MtrData` (trace list, paginated list, coverage, trace
    detail, Compare windows and paths), the dashboard MTR summary and sparklines, the Ash-backed
    trace and Compare pages, the device MTR tab and SRQL `in:mtr_traces`/`in:mtr_hops`; each
    behind its parity comparison.
    - Warehouse implementations written, selected by `Readers.enabled?/0` (the global
      `analytics.starrocks.enabled`, not the cutover list), CNPG kept for disabled installations:
      `DiagnosticsLive.MtrWarehouse` serves every `MtrData` reader (so the device MTR tab too), the
      dashboard card and sparklines, and the trace and Compare pages' Ash reads. Filters, including
      the diagnostics page's SRQL-style string (parsed in Elixir, not by the SRQL service), are one
      term list with a CNPG and a warehouse renderer. Only SQL-shape tests exist: these Elixir
      readers are not SRQL, so the 1.4 harness does not reach them and their result parity is
      still NOT proven. Still open:
      `MtrData.retention_status/1` reports the CNPG retention policy.
    - SRQL `in:mtr_traces`/`in:mtr_hops`/`in:mtr_hop_stats` (the system report panels) have a
      StarRocks dialect (`rust/srql/src/query/starrocks/mtr.rs`), and `Readers.mode_for/1` sends
      MTR SRQL to it whenever StarRocks is enabled, to CNPG otherwise. It renders the CNPG MTR
      builders' own parse of `stats:`, so both backends accept the same queries; bucket widths
      that do not divide a day, `bucket:` and `rollup_stats:` are refused. The 1.4 harness runs
      the dashboard panel shapes (`PANEL_QUERIES`) and a mixed `by addr,time:1h` shape against
      both backends; they agree.
  - [x] 3.4.7 Delete the MTR exception from the AGENTS.md JetStream rule when 3.4.1 and 3.4.3 land.
    - Done with 3.4.1: after it, no MTR path bypasses JetStream (ad-hoc traces already arrive on
      `scans.results.>` and are written inside EventWriter). 3.4.3 is about warehouse-awareness,
      not JetStream, so it does not keep the exception true.
- [ ] 3.4b BMP routing events and service status history: table, EventWriter destination, routing,
  readers.
- [ ] 3.5 Measure trace-by-id and single-device detail latency cold and warm; record against the detail-page budget.
- [ ] 3.6 Retention defaults per new dataset in Helm/Compose, applied by the existing retention task.

## 4. Bounded maintenance

- [ ] 4.1 Partition rebuild copies and catches up by hour with hour-level resume (issue #4525).
- [ ] 4.2 Long backoff on memory-limit errors; progress logged as units remaining.
- [ ] 4.3 `SET LOCAL statement_timeout = 0` and `lock_timeout = 0` on the migration lock transaction, so a replica waiting behind a long rebuild is not cancelled (issue #4525).
- [ ] 4.4 Re-run the rebuild probe on a warehouse sized to the minimum supported profile and record peak memory.

## 5. Warehouse-only telemetry when StarRocks is enabled

- [x] 5.1 Inventory every CNPG telemetry reader, UI and non-UI, by searching for each table and
  its continuous aggregates rather than for known modules; record the list in this change. It
  includes readers that bypass `Readers` today: the dashboard MTR, event and service cards, the
  logs page OTel sparklines, `Stats` events and trace summaries, the analytics page, God View
  BMP and OCSF event fetches, device risk IOC exposure, `DeviceCorrelation`, the log severity and
  trace summary refresh workers, and the service state registry queries.
  Recorded in `reader-inventory.md`, with eight findings for the 5.2-5.4 work.
- [ ] 5.2 Remove the dual-write (after 3.4 and the readers in 5.4 it would otherwise darken): with StarRocks enabled, `Destination` writes each dataset to the
  warehouse only and a warehouse failure fails the acknowledgement; every EventWriter processor
  and non-broker producer that inserts CNPG telemetry (flows, metrics, logs, events, Falco,
  Trivy, analytics signals, composite-check verdicts, credential events, endpoint inventory,
  source facts, log promotion, MTR traces including `AdhocScan`) skips the CNPG insert. Remove `shadowDatasets` and
  `cutoverDatasets` from Helm, Compose and `Env`; `Readers` routes every dataset to the warehouse
  when enabled.
- [ ] 5.3 A shared "unavailable with StarRocks enabled" result for readers with no warehouse
  implementation, rendered explicitly by each page and card, so no reader queries a frozen CNPG
  table; a test per reader until it has a warehouse implementation.
- [ ] 5.4 Give each reader from 5.1 a warehouse implementation next to its CNPG one, selected by
  `analytics.starrocks.enabled`, highest-traffic first (dashboard cards and sparklines, MTR, logs
  and events pages, OTel, sysmon, BMP, service status), each behind its parity comparison. The
  CNPG implementation stays: it serves every installation without StarRocks.
- [ ] 5.5 Optional backfill of flows and metrics history from CNPG into the warehouse for an
  installation that turns StarRocks on, newest first, in bounded units; verify counts and totals
  per day.
- [ ] 5.6 Keep the CNPG telemetry schema: no migration drops a telemetry hypertable, continuous
  aggregate, retention or compression policy, because installations without StarRocks use them.
  On a StarRocks installation they receive no rows and retention ages them out.
- [ ] 5.7 Tests: with StarRocks enabled a batch of each dataset leaves no CNPG rows; a warehouse
  load failure is redelivered, not written to CNPG; with StarRocks disabled every dataset still
  writes and reads CNPG.
- [ ] 5.8 Operator docs and CHANGELOG (BREAKING): enabling StarRocks makes every dataset
  warehouse-only at once; readers without a warehouse implementation show "unavailable"; disabling StarRocks resumes
  CNPG writes without the history written meanwhile; JetStream retention bounds a warehouse
  outage. Update `docs/docs/helm-configuration.md`, `docs/docs/netflow.md` and
  `README-Docker.md`, which describe CNPG as the flow write target.
