## 0. Preconditions and dependencies
- [x] 0.1 Get the user's decisions on the open questions (decided 2026-11-02 and 2026-11-03; recorded in design.md).
- [ ] 0.2 Confirm `platform.ocsf_findings` does not exist on staging; create it here with `add-ocsf-finding-model`'s planned schema, and keep the coordination note in both changes current.
- [ ] 0.3 Verify which NATS subject edge Falcosidekick packages publish today (`falco.>` or `events.falco.>`) and align `NatsLeafConfigGenerator` with `NatsLeafCredentials` and the chart until the removal in 6.5 lands, so no edge sender is lost before the cutoff.
- [x] 0.4 Delivery confirmation. The agent returns HTTP success only after every part is in its edge spool. Each part stays there until its JetStream PubAck. The projector does not acknowledge any source part before the occurrence and the finding update have both committed, except after a durable generic dead-letter publication of the whole set. A part that leaves the set incomplete refreshes ack progress while the window is open. The completing delivery stays unacknowledged until both writes commit or that publication is durable, and its attempts count. The finding upsert applies the count delta only when that occurrence's finding update has not yet committed, under the finding-row lock. The part stage records no count claim (design Decision 9).
- [x] 0.5 The OTLP relay contract is not this path. Falco uses `{"serviceradar.falco.event", 1}` and the agent chunks an event that does not fit in one 512 KiB edge record (design Decision 9).
- [x] 0.6 Falcosidekick is not in this path. No output extension and no fork.
- [ ] 0.7 Depend on the generic edge-record dead-letter in the EventWriter edge-record processor (`feat/edge-record-dead-letter`). Falco does not define its own dead-letter subject. A part that leaves the set incomplete refreshes ack progress while the window is open and does not approach `max_deliver`. Dead-letter a staged set only after its reassembly window expires, or a reassembled event only when the completing delivery's occurrence or finding write is about to exhaust delivery. Publish every staged sibling part's original edge record together, each with its JSON slice, and once spilled that object reference `runtime-security/raw/<yyyy-mm-dd>/<occurrence_id>.json` on each published record. Count the set, alert, and support replay. Acknowledge sources and release the stage only after that publication is durable.

## 1. Schema
- [ ] 1.1 CNPG: `platform.ocsf_findings` (planned common schema) and `finding_info_uid` on `ocsf_events`.
- [ ] 1.2 CNPG: `platform.runtime_finding_details` with indexes on status/severity, namespace/owner, `device_uid`, `node_device_uid`, `binding_status`, `last_seen`.
- [ ] 1.3 CNPG: transition outbox.
- [ ] 1.4 CNPG: `platform.runtime_security_occurrences` hypertable, day chunks, retention policy.
- [ ] 1.5 StarRocks: `serviceradar.runtime_security_occurrences` (day partitions, free-text and `raw_payload` columns `VARCHAR(1048576)`), `finding_info_uid` on `events`, warehouse retention registration.
- [ ] 1.6 `retired_at` on stateful alert rules; Ash resources in the platform schema only.

## 2. Normalizer and recognition
- [ ] 2.1 Falco projector: each part is an `EdgeRecordV1` with a journaled RFC 9562 UUIDv7 `event_id`; `falco_event_id`, `part_index`, `part_total`, and the JSON slice ride in the payload. Stage parts durably by `(falco_event_id, part_index)` and treat a redelivery of that key or edge `event_id` as the same slice. Do not acknowledge a source part before the occurrence and the finding update have both committed, except after a durable dead-letter publication of the whole set. A part that leaves the set incomplete refreshes ack progress while the window is open and is not dead-lettered. The completing delivery stays unacknowledged and its attempts count. Reassemble one slice per index, verify the digest, and hand one event to the normalizer. The part stage is a reassembly buffer and records no count claim. Apply the count delta in the finding upsert only when that occurrence's finding update has not yet committed, serialized by the finding-row lock. Release a complete set's stage only after both writes commit or that publication is durable. An expired incomplete set publishes every staged original edge record to the generic edge-record dead-letter. A Falco-shaped `logs.otel` record creates no finding.
- [ ] 2.2 `FalcoDecomposition` from the Falco JSON object: entity selection, entity key beginning with the attested partition, falco_source key `partition/rule_source/normalized hostname`, finding uid v1 hashing that partition with the entity kind, entity key, and rule, typed occurrence row, finding delta.
- [ ] 2.3 Enrich container-only records from `workload_identity_current`; partition from the attested edge record, cluster id from the agent-stamped value.
- [ ] 2.4 Occurrence id from the JSON `uuid`, else from the raw-record digest.
- [ ] 2.5 Raw evidence: inline up to 1 MiB, otherwise upload to the datasvc object store under the day-keyed reference before the occurrence write. An upload failure fails the batch. The completing delivery is still unacknowledged, so JetStream redelivers it. An in-window incomplete set is not dead-lettered. Before `max_deliver` on a reassembled event that is still unstored, publish every staged sibling part and, once spilled, the object reference together to the generic edge-record dead-letter, acknowledge sources only after that publication, and keep the object because the dead-lettered reference stays retained.

## 3. Binding
- [ ] 3.1 `DeviceCorrelation` returns `{device_uid, method, candidates}` without changing existing callers.
- [ ] 3.2 `ambiguous` on multi-device hostname matches; accepting-agent binding only when the hostname is that agent's own host. An ambiguous subject still shows on a bound node's device page.
- [ ] 3.3 `k8s_node` resolution through `k8s_nodes_current.internal_ip`.
- [ ] 3.4 Bounded re-resolution job following canonical devices.
- [ ] 3.5 Prove no inventory writes on this path (check every writer of device rows and tombstone fields).

## 4. Processing and storage
- [ ] 4.1 Occurrences to the active backend, then per-batch finding upserts in finding-row lock order with the transition outbox. Apply a count delta only when that occurrence's finding update has not yet committed. Auto-resolve and operator resolve take the same lock and re-read status and last seen. No `ocsf_events` occurrences, no `logs` rows, no alert-engine admissions for occurrences.
- [ ] 4.2 Lifecycle: auto-resolve after `runtime_findings.auto_resolve_after` (default 24 h) only when the locked row is still active and still quiet, reopen when the locked row is resolved with episode severity starting at the reopening occurrence and then rising within the episode, operator resolve from that same locked re-read. Store `status_id` 1 for active and 4 for resolved. Do not store 2 or 3.
- [ ] 4.3 Outbox relay to `ocsf_events` and `StatefulAlertEngine.evaluate_events/1`; relay age and depth published through JetStream.
- [ ] 4.4 Resolved-finding prune job.
- [ ] 4.5 `ObjectStore.RetentionWorker` runtime-evidence pass: delete a day prefix only after that day's occurrence partition or chunk is dropped, plus one day. Leave an object whose key `runtime-security/raw/<yyyy-mm-dd>/<occurrence_id>.json` a dead-lettered set still carries.

## 5. Alerting
- [ ] 5.1 Seed `falco_runtime_finding` template v1 (lifecycle only). Firing `subject_prefix` is `runtime_security.finding.firing.` with `attribute_equals` on `runtime_finding.transition` for opened, reopened, and escalated. Recovery subject is `runtime_security.finding.resolved`. Neither subject starts with `falco.`. Group by `finding_info.uid`.
- [ ] 5.2 Retired-template list in `RuleSeeder`: retire pristine `falco_critical_incident` v1 and resolve its active alerts as superseded. Do not rewrite a customized or unmanaged copy. Its `subject_prefix` `falco.` does not match `runtime_security.finding.` transitions, so the copy goes silent.
- [ ] 5.3 Remove the seeded EventRule `copyfail_falco_logs_to_security_events` from defaults and disable a pristine copy.
- [ ] 5.4 Alert detail renders the runtime finding summary and links to the finding.

## 6. Transport and packaging
- [ ] 6.1 Chart: `falcoIngest.*` values, fixed `falco-https` port 14318 with no port override, network policy admission, and the Falco namespace mTLS material plus `http_output` settings (`json_output`, output fields, tags, mTLS, `compress_uploads: false`).
- [ ] 6.2 Agent HTTPS `POST /v1/falco/events` with chart-issued mTLS. Accept the full JSON body, chunk it into `{"serviceradar.falco.event", 1}` parts when it does not fit in one 512 KiB edge record, mint one in-window UUIDv7 `event_id` per part and reuse it from the spool journal, and return success only after every part is spooled. Core seeds that contract and the agent's grant.
- [ ] 6.3 Falcosidekick collector packages: stop provisioning NATS credentials. Do not render an OTLP or Falcosidekick configuration.
- [ ] 6.4 Remove `Processors.FalcoEvents`, the `FALCO` consumer (`config.ex`, both `runtime.exs` files), and the pipeline's `falco` routing.
- [ ] 6.5 Remove `falco.>` from chart NATS permissions and leaf credentials, `events.falco.>` from `NatsLeafConfigGenerator`, the `serviceradar-falcosidekick` NATS user and its certificate generation.
- [ ] 6.6 Revoke NATS credentials of existing Falcosidekick collector packages at upgrade.

## 7. SRQL and UI
- [ ] 7.1 `in:runtime_findings`. `status:active` matches `status_id` 1 or 2, and `status:resolved` matches `status_id` 4. `partition` is a filter.
- [ ] 7.2 `in:runtime_security_occurrences` with CNPG and warehouse implementations; `raw_payload` / `raw_ref` opt-in; parity harness shapes.
- [ ] 7.3 Device page Runtime security tab (connected-only loading, SRQL paging, streams).
- [ ] 7.4 `/security` Runtime findings view with workload grouping and Unbound filter.
- [ ] 7.5 Runtime finding detail with timeline, raw evidence viewer (inline and object store, digest check), RBAC-gated resolve. The device tab lists a finding whose node is bound even when its subject is ambiguous.
- [ ] 7.6 `security-findings` dashboard package Falco frames; Logs and Events Falco source filters point to the view.

## 8. Docs
- [ ] 8.1 Operator docs: finding model, binding states, retention settings, retired rule, replacement queries.
- [ ] 8.2 Falco ingestion docs: DaemonSet `http_output` settings, mTLS, chart values, chunking and reassembly, HTTP success means the parts are spooled, no source part is acknowledged before the occurrence and the finding update commit except after a durable dead-letter publication of the whole set, an incomplete part refreshes ack progress and does not consume further delivery attempts, and an expired unfinished set or a completing delivery that would reach `max_deliver` is dead-lettered as every staged sibling part plus any spill object reference, with the stage released only after that publication is durable. Do not list a drop, truncation, oversize refusal, or a Falco-specific dead-letter subject.
- [ ] 8.3 Release notes: breaking visibility changes, the required Falco DaemonSet `http_output` cutover, no NATS fallback, forward-only migration, rollback restores the previous Falco output configuration.

## 9. Warehouse never-truncate (generic, separate)
- [ ] 9.1 Inventory every bounded warehouse text column that truncates or filters a wider value: `logs.body` (`VARCHAR(65533)`, no guard, so a wider body is filtered out of the Stream Load), event `message` (truncated in `Rows`), event document columns (dropped above 1 MiB), BMP `message`/`raw_data`, OTel span columns, flow attribution `cmdline` and related columns. Partly done for events and logs: `0036` adds `raw_data` and the other CNPG event fields to the warehouse, `0037` widens their free text (including `message` and `logs.body`) to `VARCHAR(1048576)`, and `Rows` no longer truncates it. Remaining: event/log values over 1 MiB are still dropped from their field, and BMP, OTel span and flow attribution columns still truncate (#6368).
- [ ] 9.2 Widen free-text columns to `VARCHAR(1048576)` and send values above that width out-of-line through the same object-store reference and retention mechanism as Falco evidence; remove every truncate and drop path in `ServiceRadar.Analytics.StarRocks.Rows`.
- [ ] 9.3 Make a failed spill fail the load (no silent filtering) and add regression tests per dataset on both backends. This may become its own OpenSpec change if its scope grows; it is not Falco-specific.

## 10. Tests (load the `test-audit` skill first; fixtures are synthetic only)
- [ ] 10.1 Ingest and projector: one JSON event, a multi-part event reassembled before normalize, each part's `event_id` an in-window UUIDv7 reused from the spool journal, a redelivered part index kept as one slice, an incomplete part that refreshes ack progress and is not acknowledged or dead-lettered, a completing delivery left unacknowledged until both writes commit or a durable dead-letter publication and whose attempts count, an expired incomplete set and a failed reassembled write dead-lettered as every staged sibling part plus any spill object reference with the stage released only after that publication is durable, the count delta applied once under the finding-row lock when that finding update has not committed and not applied again when it has, with no count claim on the part stage, a retried publish of a committed occurrence that does not count again, a non-JSON body rejected with no spool record.
- [ ] 10.2 Normalizer, table-driven: workload, pod, enriched container, host fallback, plugin source; uid stable across container id change and late binding; the same workload in two partitions is two findings; the same plugin rule on two hosts is two `falco_source` findings.
- [ ] 10.3 Binding DB tests (boxed sandbox): each method, ambiguous hostname, unbound, re-resolution, merged device, no device created.
- [ ] 10.4 Aggregation: per-batch fold, bounded samples, no stored window counter, concurrent two-replica upsert (unboxed, deleting its rows in `on_exit`).
- [ ] 10.5 Lifecycle and outbox: open, configurable auto-resolve, reopen at the new occurrence's severity, later escalation within that episode, crash between commit and relay, idempotent replay. Auto-resolve does not resolve a finding whose locked last seen an in-flight occurrence just advanced. An occurrence upsert reopens a row that is resolved under the finding-row lock. Operator resolve uses that same lock and re-read.
- [ ] 10.6 Alerting: a synthetic 10,000-occurrence burst across three workloads gives three `opened` admissions and three alerts; cooldown and recovery; a resolved Critical transition does not take the firing path; a `subject_prefix` of `falco.` does not match `runtime_security.finding.` transitions; no volume rule.
- [ ] 10.7 Seeder: pristine retire; a customized or unmanaged copy is not rewritten and does not match lifecycle `log_name` values under `runtime_security.finding.`.
- [ ] 10.8 Storage: StarRocks enabled writes only the warehouse, disabled writes only CNPG; inline evidence round-trips byte-exact; a 600 KiB event is chunked, reassembled, and stored inline; a 1.5 MB event is chunked, reassembled, spilled, and reads back with digest match; a refused upload fails the batch and leaves the completing delivery unacknowledged; a completing delivery that would reach `max_deliver` is dead-lettered with every staged sibling part and the spill object reference before any source is acknowledged, and the object is not deleted; retention never deletes a retained day or a dead-lettered object.
- [ ] 10.9 End-to-end on a disposable broker: Falco JSON POST to the agent, spool, reassembly, occurrence and finding; NATS `falco.*` publish refused.
- [ ] 10.10 SRQL translation tests and parity fixtures, including `partition` and `node_device_uid`; LiveView tests (device tab shows a node-bound finding with an ambiguous subject, security view, finding detail, no queries in disconnected mount, RBAC on resolve); chart unit tests for the mTLS material, Service port, and network policy.

## 11. Validation
- [x] 11.1 `openspec validate add-falco-runtime-findings --strict`.
- [ ] 11.2 `./scripts/elixir_quality.sh --project elixir/serviceradar_core` and `--project elixir/web-ng --phoenix`; `cargo fmt` / `cargo clippy` for `rust/srql`; helm unittest.
- [ ] 11.3 After the first post-deploy burst, re-query: findings, occurrences on the active backend only, one alert per finding, retired rule disabled, no `falco.*` consumer.
