## 1. Parity gate and fail-closed dialect

- [ ] 1.1 Land the pending dialect fixes found by the first cutover: tag-split series (`core_id`, `tags.<key>`) and newest-N `sort:desc limit` (PR #4526). Counter `rate`/`rate_sum` is already merged (PR #4522).
- [ ] 1.2 Land flows parity: `tcp_flags_label`, `duration_bucket`, `exporter_name` (with the reader grant), `src_cidr`/`dst_cidr` filters.
- [x] 1.3 Make the StarRocks dialect fail closed: a plan feature it does not consume (`rollup_stats`, `other`, unknown field, ignored `sort`) is an `InvalidRequest`, with a test per feature.
  - `refuse_unimplemented_features` (`rust/srql/src/query/starrocks.rs`) runs before compilation and returns `InvalidRequest` for a `rollup_stats` kind this dialect does not implement (named in the message), a rollup combined with `stats:`/`bucket:`, and `other:true` outside a grouped flow/metric stats query; an unknown field is refused by `column_sql` as `unsupported StarRocks field`. A caller's `sort` is compiled rather than dropped, including on the profile route. One test per refusal.
- [ ] 1.4 Add a repository target that seeds CNPG and StarRocks with the same synthetic rows and diffs result sets for a list of query shapes; synthetic data only.
- [ ] 1.5 Derive the per-dataset query-shape inventory from the code and check it into the harness; a test fails when a new `in:<entity>` chart query appears without an inventory entry.
- [ ] 1.6 Record each accepted deviation (approximate percentiles, sample-weighted vs mean-of-means average, inclusive vs exclusive upper bound) with its reason; align the ones that are accidents.
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
- [ ] 3.2 OTel traces/spans with RED and summary rollups as MVs; trace-by-id lookup.
- [ ] 3.3 Sysmon CPU/memory/disk/process: table(s), destination, routing, hourly rollups.
- [ ] 3.4 MTR traces and hops (spec: "MTR traces and hops reach the warehouse through JetStream").
  Scalar MTR metrics already travel on `metrics.mtr` (gateway `MtrMetricsPublisher` -> EventWriter
  `Metrics`); full traces and hops do not: scheduled results go gateway -> core
  `ResultsRouter.handle_mtr_results/1`, on-demand and bulk results go through
  `AgentCommands.StatusHandler.ingest_mtr_result/3` and `ingest_bulk_target_traces/3`, and all of
  them call `MtrMetricsIngestor.ingest/2`, which writes CNPG through Ash. Only ad-hoc scans pass
  through JetStream (`scans.results.>` -> `AdhocScan`).
  - [ ] 3.4.1 JetStream subject and stream for MTR trace results; core publishes on all three
    paths instead of calling the ingestor. Add it to the EventWriter default streams.
  - [ ] 3.4.2 EventWriter `Mtr` processor: normalizes and enriches as `MtrMetricsIngestor` does
    today, persists traces and hops (warehouse when StarRocks is enabled, CNPG otherwise), then
    runs `MtrGraph.project_traces` and `MtrPubSub.broadcast_ingest` so live pages keep updating.
    The processor is the single owner; core keeps no direct MTR write.
  - [ ] 3.4.3 Warehouse DDL `priv/starrocks/0019_mtr.sql`: `mtr_traces` and `mtr_hops` with every
    CNPG column, including probed/last-responding depth, TCP port, handshake fields and hop reply
    counters; day partitions and retention. Register the dataset in `Env`, `Destination @tables`,
    `Rows.encode_row/2`, `Retention @tables`, Helm `retentionDays` and the Compose env.
  - [ ] 3.4.4 Hop rollups as async MVs aggregating loss with `loss_ratio(sent, received)` and
    latency with `wavg(avg_us, received)`. `mtr_hops.asn` is GeoLite2-only and NULL for every
    internal hop and private AS, so an AS-level rollup is not presented as fleet-wide.
  - [ ] 3.4.5 Warehouse readers for `MtrData` (trace list, paginated list, coverage, trace
    detail, Compare windows and paths), the dashboard MTR summary and sparklines, the Ash-backed
    trace and Compare pages, the device MTR tab and SRQL `in:mtr_traces`/`in:mtr_hops`; each
    behind its parity comparison.
  - [ ] 3.4.6 Name the MTR results path in the AGENTS.md JetStream rule as a known exception
    being removed, and delete that exception when 3.4.1 lands.
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

- [ ] 5.1 Inventory every CNPG telemetry reader, UI and non-UI, by searching for each table and
  its continuous aggregates rather than for known modules; record the list in this change. It
  includes readers that bypass `Readers` today: the dashboard MTR, event and service cards, the
  logs page OTel sparklines, `Stats` events and trace summaries, the analytics page, God View
  BMP and OCSF event fetches, device risk IOC exposure, `DeviceCorrelation`, the log severity and
  trace summary refresh workers, and the service state registry queries.
- [ ] 5.2 Remove the dual-write: with StarRocks enabled, `Destination` writes each dataset to the
  warehouse only and a warehouse failure fails the acknowledgement; every EventWriter processor
  and non-broker producer that inserts CNPG telemetry (flows, metrics, logs, events, Falco,
  Trivy, analytics signals, composite-check verdicts, credential events, endpoint inventory,
  source facts, log promotion) skips the CNPG insert. Remove `shadowDatasets` and
  `cutoverDatasets` from Helm, Compose and `Env`; `Readers` routes every dataset to the warehouse
  when enabled.
- [ ] 5.3 A shared "unavailable with StarRocks enabled" result for readers with no warehouse
  implementation, rendered explicitly by each page and card, so no reader queries a frozen CNPG
  table; a test per reader until it is moved.
- [ ] 5.4 Move the readers from 5.1 to the warehouse, highest-traffic first (dashboard cards and
  sparklines, MTR, logs and events pages, OTel, sysmon, BMP, service status), each behind its
  parity comparison.
- [ ] 5.5 Backfill flows and metrics history from CNPG into the warehouse, newest first, in
  bounded units; verify counts and totals per day.
- [ ] 5.6 Separate reviewed migration(s) dropping each CNPG telemetry hypertable, its continuous
  aggregates and its retention and compression policies once no reader references it.
- [ ] 5.7 Tests: with StarRocks enabled a batch of each dataset leaves no CNPG rows; a warehouse
  load failure is redelivered, not written to CNPG; with StarRocks disabled every dataset still
  writes and reads CNPG.
- [ ] 5.8 Operator docs and CHANGELOG (BREAKING): enabling StarRocks makes every dataset
  warehouse-only at once; readers not yet moved show "unavailable"; disabling StarRocks resumes
  CNPG writes without the history written meanwhile; JetStream retention bounds a warehouse
  outage. Update `docs/docs/helm-configuration.md`, `docs/docs/netflow.md` and
  `README-Docker.md`, which describe CNPG as the flow write target.
