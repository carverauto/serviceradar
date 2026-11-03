## 0. Preconditions
- [ ] 0.1 Get the user's answers to the design's open questions (logs row, exact counts, window alerting, quiet period, backfill, sequencing with `add-ocsf-finding-model`).
- [ ] 0.2 Confirm whether `platform.ocsf_findings` exists on staging; if not, this change creates it with the common columns from `add-ocsf-finding-model` and records that in that change's tasks 1.1, 2.3, 2.4 and 3.1.
- [ ] 0.3 Verify which Falcosidekick NATS subject edge packages publish (`falco.>` vs `events.falco.>`) and align `NatsLeafConfigGenerator` with `NatsLeafCredentials` and the chart.
- [ ] 0.4 Verify Falcosidekick's NATS output publishes without a JetStream PubAck and record it in operator docs.

## 1. Schema
- [ ] 1.1 CNPG migration: `platform.runtime_finding_details` (typed columns, indexes on status/severity, namespace/owner, `device_uid`, `node_device_uid`, `binding_status`, `last_seen`), cascading from `ocsf_findings`.
- [ ] 1.2 CNPG migration: the runtime finding transition outbox.
- [ ] 1.3 CNPG migration: `platform.runtime_security_occurrences` hypertable with a retention policy, keyed on `(time, id)`.
- [ ] 1.4 StarRocks migration: `serviceradar.runtime_security_occurrences`, day-partitioned, `raw_payload VARCHAR(1048576)`, registered with warehouse retention.
- [ ] 1.5 Add `retired_at` to stateful alert rules.
- [ ] 1.6 Ash resources for findings and details, platform schema only, no multitenancy bypass.

## 2. Normalizer
- [ ] 2.1 Extend `FalcoDecomposition` with entity selection, entity key, finding uid v1, typed occurrence row, and finding delta; one entry point taking a decoded record plus ingest metadata.
- [ ] 2.2 Enrich container-only records from `workload_identity_current`.
- [ ] 2.3 Read `serviceradar.cluster_id` / `serviceradar.partition`, defaulting cluster to `default`.
- [ ] 2.4 Derive occurrence ids identically on the direct and log-promotion paths.
- [ ] 2.5 Byte-exact raw evidence with digest, length, and the oversize path (counter and health event).

## 3. Binding
- [ ] 3.1 Return `{device_uid, method, candidates}` from `DeviceCorrelation` without changing existing callers' behavior; the inferred agent id counts only when the agent exists.
- [ ] 3.2 Report `ambiguous` for multi-device hostname matches on the runtime-finding path.
- [ ] 3.3 Add `k8s_node` resolution through `k8s_nodes_current.internal_ip`.
- [ ] 3.4 Bounded re-resolution Oban job for unbound, ambiguous, deleted and merged bindings, following canonical devices.
- [ ] 3.5 Prove no inventory writes on this path (grep every writer of device rows and tombstone fields).

## 4. Processing and storage
- [ ] 4.1 `FalcoEvents`: write occurrences to the active backend, then upsert findings per batch in uid lock order; stop writing `ocsf_events` occurrences, the per-occurrence `logs` row (pending 0.1), and alert-engine admissions.
- [ ] 4.2 `LogPromotion`: route promoted Falco records through the same normalizer and storage.
- [ ] 4.3 Occurrence writer on both backends via the EventWriter destination; never both.
- [ ] 4.4 Lifecycle: auto-resolve job, reopen, suppression with expiry, operator resolve.
- [ ] 4.5 Transition outbox write in the finding transaction, plus the relay to `ocsf_events` and `StatefulAlertEngine.evaluate_events/1`; publish relay age/depth through JetStream.
- [ ] 4.6 Resolved-finding prune job.

## 5. Alerting
- [ ] 5.1 Seed `falco_runtime_finding` template v1.
- [ ] 5.2 Add the retired-template list to `RuleSeeder`; retire pristine `falco_critical_incident` v1, resolve its active alerts as superseded, and flag customized copies in Rules settings.
- [ ] 5.3 Alert detail renders the runtime finding summary and links to the finding.

## 6. SRQL
- [ ] 6.1 `in:runtime_findings` entity, fields, aliases, stats.
- [ ] 6.2 `in:runtime_security_occurrences` with CNPG and warehouse implementations; raw payload opt-in.
- [ ] 6.3 Add occurrence query shapes to the result-diff parity harness.
- [ ] 6.4 SRQL catalog and docs entries.

## 7. UI
- [ ] 7.1 Device page Runtime security tab (connected-only loading, SRQL paging, streams).
- [ ] 7.2 `/security` Runtime findings view with workload grouping and Unbound filter.
- [ ] 7.3 Runtime finding detail page with timeline, raw evidence viewer and RBAC-gated actions.
- [ ] 7.4 Move Falco frames in the `security-findings` dashboard package to `in:runtime_findings`.
- [ ] 7.5 Point the Logs and Events Falco source filters at the runtime findings view.

## 8. Packaging and docs
- [ ] 8.1 Falcosidekick collector bundle: add `serviceradar.cluster_id` and `serviceradar.partition` custom fields.
- [ ] 8.2 Operator docs: finding model, binding states, retention settings, retired rule, replacement queries, publisher-side loss window.
- [ ] 8.3 Release notes: the breaking visibility changes and forward-only migration.

## 9. Tests (load the `test-audit` skill first; fixtures are synthetic only)
- [ ] 9.1 Pure normalizer tests, table-driven: workload, pod, enriched container, host fallback, plugin source; uid stable across container id change and late binding.
- [ ] 9.2 Binding DB tests (boxed sandbox): each method, ambiguous hostname, unbound, re-resolution, merged device, no device created.
- [ ] 9.3 Aggregation: per-batch fold, bounded samples, window rollover, and a concurrent two-replica upsert test (unboxed, deleting its rows in `on_exit`).
- [ ] 9.4 Lifecycle and outbox: open, auto-resolve, reopen, suppress, escalate; crash between commit and relay; idempotent replay.
- [ ] 9.5 Alerting: synthetic 10,000-occurrence burst across three workloads produces three `opened` admissions and three alerts; cooldown and recovery.
- [ ] 9.6 Seeder: pristine retire, customized left and flagged, unmanaged left.
- [ ] 9.7 Storage: StarRocks enabled writes only the warehouse; disabled writes only CNPG; raw payload round-trips byte-exact on both; oversize path.
- [ ] 9.8 SRQL translation tests and parity fixtures for both entities.
- [ ] 9.9 LiveView tests: device tab, security view, finding detail, no queries in disconnected mount, RBAC.

## 10. Validation
- [x] 10.1 `openspec validate add-falco-runtime-findings --strict`.
- [ ] 10.2 `./scripts/elixir_quality.sh --project elixir/serviceradar_core` and `--project elixir/web-ng --phoenix`; `cargo fmt` and `cargo clippy` for `rust/srql`.
- [ ] 10.3 Re-query after the first post-deploy burst: findings, occurrences on the active backend only, one alert per finding, retired rule disabled.
