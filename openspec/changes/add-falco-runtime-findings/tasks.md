## 0. Preconditions and dependencies
- [x] 0.1 Get the user's decisions on the open questions (decided 2026-11-02 and 2026-11-03; recorded in design.md).
- [ ] 0.2 Confirm `platform.ocsf_findings` does not exist on staging; create it here with `add-ocsf-finding-model`'s planned schema, and keep the coordination note in both changes current.
- [ ] 0.3 Verify which NATS subject edge Falcosidekick packages publish today (`falco.>` or `events.falco.>`) and align `NatsLeafConfigGenerator` with `NatsLeafCredentials` and the chart until the removal in 6.5 lands, so no edge sender is lost before the cutoff.
- [x] 0.4 Delivery confirmation. Falcosidekick's NATS output has no JetStream PubAck. On the edge path, a record is durably held from OTLP acceptance by the agent's receiver through to a JetStream PubAck (design Decision 9). The remaining sender-hop and spool-eviction loss points are documented in 8.2.
- [ ] 0.5 Dependency: sibling task 4.1 of `move-agent-telemetry-to-edge-records` (`OtlpRelayFrame` producer and projector, #6262) ships in the same or an earlier release, including refusal back to the sender (never a drop) of a single OTLP record above the 512 KiB record bound.
- [ ] 0.6 Dependency: extend Falcosidekick's OTLP logs output (all fields, `falco.event`, `falco.uuid`, priority severity, resource from `OTEL_RESOURCE_ATTRIBUTES`, logs-specific `checkcert`); upstream it, and pin the fork build until an upstream release contains it.

## 1. Schema
- [ ] 1.1 CNPG: `platform.ocsf_findings` (planned common schema) and `finding_info_uid` on `ocsf_events`.
- [ ] 1.2 CNPG: `platform.runtime_finding_details` with indexes on status/severity, namespace/owner, `device_uid`, `node_device_uid`, `binding_status`, `last_seen`.
- [ ] 1.3 CNPG: transition outbox.
- [ ] 1.4 CNPG: `platform.runtime_security_occurrences` hypertable, day chunks, retention policy.
- [ ] 1.5 StarRocks: `serviceradar.runtime_security_occurrences` (day partitions, free-text and `raw_payload` columns `VARCHAR(1048576)`), `finding_info_uid` on `events`, warehouse retention registration.
- [ ] 1.6 `retired_at` on stateful alert rules; Ash resources in the platform schema only.

## 2. Normalizer and recognition
- [ ] 2.1 Recognizer in the `Logs` processor: relay headers, resource, scope and required attributes; malformed and unrelayed counters; per-record routing with one ACK decision per message.
- [ ] 2.2 `FalcoDecomposition` from OTLP attributes: entity selection, entity key, finding uid v1, typed occurrence row, finding delta.
- [ ] 2.3 Enrich container-only records from `workload_identity_current`; partition from `Sr-Partition`, cluster from the resource attribute.
- [ ] 2.4 Occurrence id from `falco.uuid`, else from the raw-record digest.
- [ ] 2.5 Raw evidence: inline up to 1 MiB, otherwise upload to the datasvc object store under the day-keyed reference before the occurrence write; an upload failure fails the batch.

## 3. Binding
- [ ] 3.1 `DeviceCorrelation` returns `{device_uid, method, candidates}` without changing existing callers.
- [ ] 3.2 `ambiguous` on multi-device hostname matches; relaying-agent binding only when colocated.
- [ ] 3.3 `k8s_node` resolution through `k8s_nodes_current.internal_ip`.
- [ ] 3.4 Bounded re-resolution job following canonical devices.
- [ ] 3.5 Prove no inventory writes on this path (check every writer of device rows and tombstone fields).

## 4. Processing and storage
- [ ] 4.1 Occurrences to the active backend, then per-batch finding upserts in uid lock order with the transition outbox; no `ocsf_events` occurrences, no `logs` rows, no alert-engine admissions for occurrences.
- [ ] 4.2 Lifecycle: auto-resolve after `runtime_findings.auto_resolve_after` (default 24 h), reopen, suppression with expiry, operator resolve.
- [ ] 4.3 Outbox relay to `ocsf_events` and `StatefulAlertEngine.evaluate_events/1`; relay age and depth published through JetStream.
- [ ] 4.4 Resolved-finding prune job.
- [ ] 4.5 `ObjectStore.RetentionWorker` runtime-evidence pass: delete a day prefix only after that day's occurrence partition or chunk is dropped, plus one day.

## 5. Alerting
- [ ] 5.1 Seed `falco_runtime_finding` template v1 (lifecycle only).
- [ ] 5.2 Retired-template list in `RuleSeeder`: retire pristine `falco_critical_incident` v1, resolve its active alerts as superseded, flag customized copies in Rules settings.
- [ ] 5.3 Remove the seeded EventRule `copyfail_falco_logs_to_security_events` from defaults and disable a pristine copy.
- [ ] 5.4 Alert detail renders the runtime finding summary and links to the finding.

## 6. Transport and packaging
- [ ] 6.1 Chart: `falcoIngest.*` values, `agent.otlpReceiver.port` (default 14317), the `otlp-grpc` Service port, network policy admission, and the `serviceradar-falcosidekick-otlp` Secret (OTLP environment, ingestion token, CA).
- [ ] 6.2 Core: managed `otel-collector` add-on assignment for the in-cluster agent (TLS, token auth, port), OTLP relay contract registry entry and grant. First verify the add-on delivery model the in-cluster agent uses.
- [ ] 6.3 Falcosidekick collector package: render the OTLP configuration for the site's agent; stop provisioning NATS credentials.
- [ ] 6.4 Remove `Processors.FalcoEvents`, the `FALCO` consumer (`config.ex`, both `runtime.exs` files), and the pipeline's `falco` routing.
- [ ] 6.5 Remove `falco.>` from chart NATS permissions and leaf credentials, `events.falco.>` from `NatsLeafConfigGenerator`, the `serviceradar-falcosidekick` NATS user and its certificate generation.
- [ ] 6.6 Revoke NATS credentials of existing Falcosidekick collector packages at upgrade.

## 7. SRQL and UI
- [ ] 7.1 `in:runtime_findings`.
- [ ] 7.2 `in:runtime_security_occurrences` with CNPG and warehouse implementations; `raw_payload` / `raw_ref` opt-in; parity harness shapes.
- [ ] 7.3 Device page Runtime security tab (connected-only loading, SRQL paging, streams).
- [ ] 7.4 `/security` Runtime findings view with workload grouping and Unbound filter.
- [ ] 7.5 Runtime finding detail with timeline, raw evidence viewer (inline and object store, digest check), RBAC-gated actions.
- [ ] 7.6 `security-findings` dashboard package Falco frames; Logs and Events Falco source filters point to the view.

## 8. Docs
- [ ] 8.1 Operator docs: finding model, binding states, retention settings, retired rule, replacement queries.
- [ ] 8.2 Falco ingestion docs: Falcosidekick OTLP configuration, chart values, the pinned Falcosidekick build, delivery guarantee and the two residual loss points with their counters.
- [ ] 8.3 Release notes: breaking visibility changes, the required Falcosidekick reconfiguration, no NATS fallback, forward-only migration, rollback needs the old Falcosidekick configuration.

## 9. Warehouse never-truncate (generic, separate)
- [ ] 9.1 Inventory every bounded warehouse text column that truncates or filters a wider value: `logs.body` (`VARCHAR(65533)`, no guard, so a wider body is filtered out of the Stream Load), event `message` (truncated in `Rows`), event document columns (dropped above 1 MiB), BMP `message`/`raw_data`, OTel span columns, flow attribution `cmdline` and related columns.
- [ ] 9.2 Widen free-text columns to `VARCHAR(1048576)` and send values above that width out-of-line through the same object-store reference and retention mechanism as Falco evidence; remove every truncate and drop path in `ServiceRadar.Analytics.StarRocks.Rows`.
- [ ] 9.3 Make a failed spill fail the load (no silent filtering) and add regression tests per dataset on both backends. This may become its own OpenSpec change if its scope grows; it is not Falco-specific.

## 10. Tests (load the `test-audit` skill first; fixtures are synthetic only)
- [ ] 10.1 Recognizer: relayed, malformed, unrelayed and mixed messages.
- [ ] 10.2 Normalizer, table-driven: workload, pod, enriched container, host fallback, plugin source; uid stable across container id change and late binding.
- [ ] 10.3 Binding DB tests (boxed sandbox): each method, ambiguous hostname, unbound, re-resolution, merged device, no device created.
- [ ] 10.4 Aggregation: per-batch fold, bounded samples, window rollover, concurrent two-replica upsert (unboxed, deleting its rows in `on_exit`).
- [ ] 10.5 Lifecycle and outbox: open, configurable auto-resolve, reopen, suppress, escalate; crash between commit and relay; idempotent replay.
- [ ] 10.6 Alerting: a synthetic 10,000-occurrence burst across three workloads gives three `opened` admissions and three alerts; cooldown and recovery; no volume rule.
- [ ] 10.7 Seeder: pristine retire, customized left and flagged, unmanaged left.
- [ ] 10.8 Storage: StarRocks enabled writes only the warehouse, disabled writes only CNPG; inline evidence round-trips byte-exact; a 1.5 MB record spills, references, reads back with digest match; a refused upload fails the batch; retention never deletes a retained day.
- [ ] 10.9 End-to-end on a disposable broker: Falcosidekick (pinned build) to the add-on to agent spool to projector to `logs.otel` to occurrence and finding; NATS `falco.*` publish refused.
- [ ] 10.10 SRQL translation tests and parity fixtures; LiveView tests (device tab, security view, finding detail, no queries in disconnected mount, RBAC); chart unit tests for the Secret, Service port and network policy.

## 11. Validation
- [x] 11.1 `openspec validate add-falco-runtime-findings --strict`.
- [ ] 11.2 `./scripts/elixir_quality.sh --project elixir/serviceradar_core` and `--project elixir/web-ng --phoenix`; `cargo fmt` / `cargo clippy` for `rust/srql`; helm unittest.
- [ ] 11.3 After the first post-deploy burst, re-query: findings, occurrences on the active backend only, one alert per finding, retired rule disabled, no `falco.*` consumer.
