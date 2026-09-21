## 1. Parity gate and fail-closed dialect

- [ ] 1.1 Land the pending dialect fixes found by the first cutover: tag-split series (`core_id`, `tags.<key>`) and newest-N `sort:desc limit` (PR #4526). Counter `rate`/`rate_sum` is already merged (PR #4522).
- [ ] 1.2 Land flows parity: `tcp_flags_label`, `duration_bucket`, `exporter_name` (with the reader grant), `src_cidr`/`dst_cidr` filters.
- [ ] 1.3 Make the StarRocks dialect fail closed: a plan feature it does not consume (`rollup_stats`, `other`, unknown field, ignored `sort`) is an `InvalidRequest`, with a test per feature.
- [ ] 1.4 Add a repository target that seeds CNPG and StarRocks with the same synthetic rows and diffs result sets for a list of query shapes; synthetic data only.
- [ ] 1.5 Derive the per-dataset query-shape inventory from the code and check it into the harness; a test fails when a new `in:<entity>` chart query appears without an inventory entry.
- [ ] 1.6 Record each accepted deviation (approximate percentiles, sample-weighted vs mean-of-means average, inclusive vs exclusive upper bound) with its reason; align the ones that are accidents.
- [ ] 1.7 `other:true` top-N with an "Other" tail for flows and metrics.

## 2. Logs and events: reads to parity, then cut over

- [ ] 2.1 Day-partitioned async MVs for log severity counts and event anomaly-finding counts; `rollup_stats:severity` and `rollup_stats:anomaly_findings` compile to them, with `RollupFreshness` fallback to raw.
- [ ] 2.2 Logs filter vocabulary on StarRocks: `severity`, `level`, `severity_match`, `device_id`.
- [ ] 2.3 Events filter vocabulary on StarRocks: `log_level`, `event_type`, `host`, `device_id`, `finding_uid`.
- [ ] 2.4 Route the direct CNPG readers through `Readers`: dashboard throughput sparklines, device Flows-tab presence probes, and any logs/events stat card that bypasses SRQL.
- [ ] 2.5 Measure log search on the deployed profile: which index types shared-data supports, and latency of a substring search over 1, 30 and 365 days; document the supported behaviour.
- [ ] 2.6 Run the parity harness for `logs` and `events`; cut each over in demo values only after it passes; verify cards and charts against ground truth after the rollout completes.

## 3. Extend the warehouse to the remaining telemetry

- [ ] 3.1 OTel metric points and metric definitions: table, EventWriter destination, SRQL dataset routing, parity.
- [ ] 3.2 OTel traces/spans with RED and summary rollups as MVs; trace-by-id lookup.
- [ ] 3.3 Sysmon CPU/memory/disk/process: table(s), destination, routing, hourly rollups.
- [ ] 3.4 MTR traces and hops, BMP routing events, service status history.
- [ ] 3.5 Measure trace-by-id and single-device detail latency cold and warm; record against the detail-page budget.
- [ ] 3.6 Retention defaults per new dataset in Helm/Compose, applied by the existing retention task.

## 4. Bounded maintenance

- [ ] 4.1 Partition rebuild copies and catches up by hour with hour-level resume (issue #4525).
- [ ] 4.2 Long backoff on memory-limit errors; progress logged as units remaining.
- [ ] 4.3 `SET LOCAL statement_timeout = 0` and `lock_timeout = 0` on the migration lock transaction, so a replica waiting behind a long rebuild is not cancelled (issue #4525).
- [ ] 4.4 Re-run the rebuild probe on a warehouse sized to the minimum supported profile and record peak memory.

## 5. Retire telemetry from CNPG

- [ ] 5.1 Inventory every non-UI reader of each telemetry table (grep for the table and its CAGGs, not for the obvious module); complete `add-starrocks-telemetry-analytics` task 5.4 for metrics and the equivalent for each other dataset.
- [ ] 5.2 Per-dataset `cnpgWrites` switch in Helm/Compose, default on; EventWriter honours it; turning it off is refused at startup unless the dataset is cut over, its non-UI consumer inventory is recorded complete and migrated, and the declared soak has elapsed since cutover with no reader errors.
- [ ] 5.3 Backfill flows and metrics history from CNPG into the warehouse, newest first, in bounded units; verify counts and totals per day.
- [ ] 5.4 After the soak: stop CNPG writes for flows, then metrics, then logs, events and the rest; re-query after each to confirm no new rows and no reader errors.
- [ ] 5.5 Separate reviewed migration(s) dropping each retired hypertable, its continuous aggregates, retention and compression policies and jobs; only after the retirement hold (writes off, no reader errors) has elapsed for the dataset.
- [ ] 5.6 Operator docs: what lives where, the one-way steps, retention and cost guidance, freshness and search behaviour.
