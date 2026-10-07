## 1. Warehouse table and ingest
- [x] 1.1 Add `priv/starrocks/00NN_flow_process_attribution_observations.sql`: Duplicate Key, daily `date_trunc` partitions on `observed_at`, columns covering the current observation payload; register it with the schema migrator and add it to `Retention.tables/0` as dataset `attribution`.
- [x] 1.2 Publish admitted `FlowAttributionEvent` batches from `StatusHandler` to `flows.attribution.observations` (flow demand domain) instead of calling `FlowAttribution.persist/4`; keep bounded admission.
- [x] 1.3 Add the EventWriter processor and stream/consumer config that Stream-Loads observations into the new table; grant the NATS publish/subscribe permissions in the Helm chart.
- [x] 1.4 Tests: publisher emits the subject with the expected payload; processor maps rows to the table columns; admission stays bounded.

## 2. In-warehouse correlation
- [x] 2.1 Replace `warehouse_correlation_sql` with one StarRocks statement joining recent unattributed flows to live observation partitions, preserving every candidate family and precedence rank from *Correlation Is Protocol-Aware And Exact-First*.
- [x] 2.2 Pass agent node IPs and public endpoint backends read from CNPG as bound parameters.
- [x] 2.3 Enrich matched rows with workload identity by `(agent_id, container_id)` from CNPG for the stamped batch only.
- [x] 2.4 Keep publishing stamps on `events.flow.attribution` with `flow_attribution_update_version`; `FlowAttributionUpdates` unchanged.
- [x] 2.5 Tests at the correlation boundary: one case per precedence rank, newest-wins within a rank, relaxed-UDP ambiguity, ICMP without port equality, node-SNAT, public endpoint ordering, and a flow outside the window staying unattributed.

## 3. Delete the CNPG path
- [x] 3.1 Remove `Persistence.insert_current_rows/1`, `Retention`, `WorkloadBackfill`, and the CNPG correlation SQL and lock.
- [x] 3.2 Migration dropping `platform.flow_process_attribution_current` and its indexes.
- [x] 3.3 Without StarRocks: publisher and correlator do not run; health reports `attribution_disabled: starrocks_required`. Test it.
- [x] 3.4 Grep the workspace (web-ng, SRQL, docs, Helm) for remaining references and remove them.

## 4. Data retention settings (all warehouse datasets)
- [x] 4.1 CNPG settings resource: one row per dataset (days, updated_by/at, last applied value, status, error); migration.
- [x] 4.2 Seed rows from `Env` (`SERVICERADAR_STARROCKS_RETENTION_DAYS_<DATASET>`, Helm `analytics.starrocks.retentionDays`, Compose) when absent; add `attribution` (default 30) to Env, Helm values, Compose and docs; demo Helm values set attribution to 1.
- [x] 4.3 `Retention` reads the stored settings, re-applies a dataset on change without restart, keeps retry/backoff, records outcome on the row, and enforces per-dataset floors (attribution: 1 day, never fewer than 2 live partitions).
- [x] 4.4 web-ng "Data retention" Settings page, RBAC view/manage permissions: effective value, seed default, last applied status/time per dataset; floor validation; storage warning for large values.
- [x] 4.5 Tests: seed from env; a saved change issues the ALTER for that dataset only and records `applied`; Frontend unavailable records `pending` and retries; below-floor values rejected; attribution default 30. Update the Helm checksum pin if the defaults block changes.

## 5. Observability
- [x] 5.1 Emit correlator pass duration, flows read, matches by strategy, stamped count, observation lag, ingest rate and live partition count as metrics through JetStream.

## 6. Load-test gate
- [x] 6.1 Replay demo-scale observation and flow rates against a warehouse for several hours.
- [x] 6.2 Gate: correlation p95 well under the pass interval, zero failed passes, observation table size flat at steady state (bounded by live partitions), attribution coverage no worse than the CNPG path.
- [x] 6.3 Record the numbers in the PR, including storage per day of observations.
- [x] 6.4 (Not needed: correlation p95 stayed under 1 s with duplicates included; see PR #5164.) Only if the load test shows observation volume matters: coalesce duplicate `(partition, attribution_key)` rows within an EventWriter batch.

## 7. Cutover
- [x] 7.1 Ship in one release; verify on demo that observations land, passes succeed and flows are stamped.
