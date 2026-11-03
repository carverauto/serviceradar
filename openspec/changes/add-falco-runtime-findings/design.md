# Design: Falco runtime findings

## Context

### Ingestion today

- **Direct path.** Falco posts to Falcosidekick. Falcosidekick publishes to `falco.>` subjects
  on NATS; the chart grants the `serviceradar-falcosidekick` identity `falco.>` and leaf
  credentials allow `falco.>`. JetStream stream `events` captures the subject, and the EventWriter
  pipeline routes any `falco` / `falco.*` subject to
  `ServiceRadar.EventWriter.Processors.FalcoEvents` (`pipeline.ex` `falco_subject?/1`; consumer
  `FALCO` on `falco.logs`, batch 100).
- **Log path.** A Falco record that arrives as a log (for example over OTLP into `logs.otel`)
  is stored by the `Logs` processor. If an EventRule promotes it, for example the seeded
  `copyfail_falco_logs_to_security_events`, `LogPromotion.enrich_falco_event/3` decorates the
  promoted event with the same decomposition.
- **Shared decomposition.** `ServiceRadar.EventWriter.FalcoDecomposition` already extracts
  context, diagnostics (process, parent, user, file, network, container, Kubernetes), MITRE
  `attacks`, observables, an attribution status, and a `finding_info` whose uid is a hash of
  `{rule, source, subject, class_uid, hostname, namespace, pod, container_id}`.
- **Per event, FalcoEvents writes:** a `logs` row with the whole payload in `attributes`; an
  `ocsf_events` row (class 2004 by default) with `message = output`, `unmapped = payload`,
  `raw_data = raw bytes` and `metadata.security_signal.diagnostics`; both datasets through
  `Destination.persist_after_cnpg/3`; then `StatefulEvaluationLedger.evaluate_once/1`, which
  admits every promoted row into `StatefulAlertEngine`.
- **Alerting.** The managed rule `falco_critical_incident` (template v1) matches
  `log_name` prefix `falco.` and severity >= Critical, `group_by: ["rule", "hostname"]`,
  threshold 1, 300 s window, 300 s cooldown, 6 h renotify.
- **Device correlation.** `DeviceCorrelation.resolve/1` tries the explicit uid, then the agent id
  (including an inferred `agent-<hostname>`), then `platform.workload_identity_current` by pod
  uid, pod name or container id, then IP, then hostname. The hostname lookup takes the first
  match by `is_active, last_seen_time, modified_time, uid` when several devices share it.
- **Warehouse limits.** `ServiceRadar.Analytics.StarRocks.Rows` truncates the event `message`
  to 65,533 bytes and drops any document column over 1,048,576 bytes. The warehouse `events`
  table has no `raw_data` column.

### Adjacent state that this change reuses

- `platform.workload_identity_current`: container id to pod uid, namespace, name, image and
  agent, per partition.
- `platform.k8s_nodes_current`: node name, uid, cluster id, internal and external IP.
- `add-ocsf-finding-model` (pending, almost unimplemented): one `platform.ocsf_findings` table
  with common indexed columns plus class JSONB; occurrences stay as events that reference the
  finding.
- Vulnerability assessments set the house pattern this change follows: current state in CNPG
  (`endpoint_vulnerability_assessments`), with history and analytics in the warehouse.

## Goals / Non-Goals

- Goals: one actionable record per (entity, rule); every finding tied to an inventory device or
  Kubernetes workload, or explicitly marked as not tied; alert volume proportional to distinct
  findings; raw evidence never truncated; storage that follows the JetStream-first and one-backend
  rules.
- Non-Goals: the generic alert-admission no-loss fix; changing Falco rules or priorities;
  rule-level suppression policies (for example "expected in CI namespaces"); mapping Falco plugin
  sources (k8saudit, cloud audit logs) to their native subjects; Trivy and endpoint-inventory
  mapping onto `ocsf_findings` (still owned by `add-ocsf-finding-model`); a Kubernetes workload
  inventory page.

## Decisions

### Decision 1: Findings live in `platform.ocsf_findings` plus a typed runtime extension

A runtime finding is a row in `platform.ocsf_findings` (class 2004, `source = 'falco'`), with a
1:1 row in `platform.runtime_finding_details` keyed by `finding_uid` (`ON DELETE CASCADE`).

- **Why the canonical table.** `add-ocsf-finding-model` already decided that every finding class
  shares one store. A Falco-only findings table would be the parallel abstraction that change
  exists to prevent. This change creates `ocsf_findings` with the common columns that design
  lists if it does not exist yet, and `add-ocsf-finding-model` extends it for its other producers.
- **Why an extension table.** The runtime attributes SRQL must filter on (rule, priority,
  cluster, namespace, owner, pod, node, image, process, user, tactic, technique) do not belong
  as columns on a cross-class table, and JSONB-only filtering is what makes today's records hard
  to query. Typed columns give indexed filters; class JSONB keeps the full OCSF finding payload.
- **Columns (common, `ocsf_findings`):** `uid` (PK, the `finding_info.uid`), `class_uid`,
  `source`, `status` (`active`, `suppressed`, `resolved`), `severity_id` (maximum over the
  current episode), `title`, `first_seen`, `last_seen`, `occurrence_count` (lifetime),
  `episode_started_at`, `episode_occurrence_count`, `reopen_count`, `device_uid` (the subject's
  binding), `binding_status`, `payload` (full OCSF Detection Finding JSONB), `inserted_at`,
  `updated_at`.
- **Columns (runtime, `runtime_finding_details`):** `rule`, `rule_source` (Falco `source`, for
  example `syscall`), `priority`, `entity_kind`, `entity_key`, `cluster_id`, `partition`,
  `namespace`, `owner_kind`, `owner_name`, `pod_name`, `hostname`, `node_device_uid`,
  `node_binding_status`, `binding_method`, `binding_candidates`, `attribution_status`,
  `tactics text[]`, `techniques text[]`, `window_started_at`, `window_count`, `samples jsonb`
  (bounded, Decision 4), `first_occurrence_id`, `latest_occurrence_id`, `last_resolved_at`,
  `suppressed_until`, `suppressed_by`, `suppression_reason`, plus `transition_seq` (Decision 7).

### Decision 2: The subject entity is the most specific stable one

The normalizer chooses one subject per occurrence, in this order:

| `entity_kind` | When | `entity_key` coordinates |
| --- | --- | --- |
| `k8s_workload` | namespace and an owner kind and name are known | `cluster_id / namespace / owner_kind / owner_name` |
| `k8s_pod` | namespace and pod are known, owner is not | `cluster_id / namespace / pod_name` |
| `host` | a `syscall` event with no Kubernetes pod context (bare host, Docker host, nested runtime) | `partition / normalized hostname` |
| `falco_source` | a non-`syscall` source (plugin events) | `partition / rule_source / normalized hostname` |

- **Owner sources**, in order: owner fields Falco emits when its Kubernetes metadata plugin is
  enabled or when they are set as custom fields; owner fields on the matching
  `workload_identity_current` row once `add-workload-identity-enrichment` adds owner chains.
  No pod-name parsing heuristic infers an owner: a guessed owner can merge two unrelated
  workloads, and the shape of the failure (silently combined evidence) is worse than a pod-level
  finding that splits on rollout. A pod-level finding records `attribution_status = partial` and
  the UI says the owner is unknown.
- **Container-only events** (a container id with no Kubernetes fields) are first enriched from
  `workload_identity_current` by `(partition, container_id)`. If that yields a pod, the event
  becomes `k8s_pod` or `k8s_workload` with `attribution_status = enriched`. Otherwise its subject
  is the `host` and the container id and image are occurrence attributes and finding samples.
- **Cluster identity.** Falco does not report a cluster. The Falcosidekick collector bundle sets
  the custom fields `serviceradar.cluster_id` and `serviceradar.partition`. A missing cluster
  id is the literal `default`, so a single-cluster installation needs no configuration.
- **Finding identity.** `uid = deterministic_uuid("falco:runtime-finding:v1:" <> entity_kind <>
  "|" <> entity_key <> "|" <> rule)`. It never includes `container_id`, pod uid, device uid or the
  ingest subject. Because the uid is derived from **observed** coordinates, a device binding can
  arrive, change or be cleared without changing the finding's identity, and a DIRE merge moves
  the binding, not the finding.
- **Rule identity** is the Falco rule name. A renamed rule is a new finding; that is correct,
  because Falco gives no stable rule id across versions.

### Decision 3: Inventory binding records how it was made, and never guesses

Binding uses `DeviceCorrelation`, extended to return `{device_uid | nil, method, candidates}`
instead of a bare uid. The same resolution is computed for the subject (`device_uid`) and for
the node the occurrence ran on (`node_device_uid`); for a `host` subject they are the same.

- **Methods, strongest first:** `explicit_uid` (a `service_radar.device_uid` field), `agent` (an
  agent id that exists; an inferred `agent-<hostname>` counts only when that agent exists),
  `workload_identity` (container or pod to agent to device), `k8s_node` (node name to
  `k8s_nodes_current.internal_ip`, then to a device by IP in the partition), `hostname_unique`.
- **Ambiguity is a state.** A hostname lookup that matches more than one non-deleted device
  yields `binding_status = ambiguous` with `binding_candidates = n`, and no `device_uid`.
  Hostnames repeat across sites and clusters; choosing by sort order ties evidence to the wrong
  machine without saying so.
- **Unbound is a state.** No candidate yields `binding_status = unbound`. The finding is still
  created, listed under "Unbound runtime findings", and shown on no device page.
- **Re-resolution.** A bounded periodic job re-runs binding for findings that are `unbound`,
  `ambiguous`, or bound to a device that is now deleted or merged. A merge follows the canonical
  device through the existing merge/alias lookup. Each run takes at most a fixed page of findings,
  ordered by `last_seen` descending.
- **Occurrences keep their ingest-time binding.** An occurrence row is append-only evidence of
  what was resolvable when it arrived. The finding carries the current binding.
- **Falco is not an inventory source.** Binding SHALL NOT create devices, merge them, contribute
  identity facts, or clear tombstones. That keeps it out of the three tombstone-clearing writers
  the device-identity rules call out.

### Decision 4: Aggregation is per batch, atomic per finding, with bounded samples

- The processor groups a batch's occurrences by finding uid and issues one upsert per finding.
- The upsert runs in one CNPG transaction that locks the affected findings in uid order (to
  avoid deadlocks between EventWriter replicas), then sets `occurrence_count += n`,
  `episode_occurrence_count += n`, `first_seen = least(...)`, `last_seen = greatest(...)`,
  `severity_id = greatest(...)` within the episode, and merges samples.
- **Fixed window.** `window_started_at` / `window_count` is a tumbling one-hour window: an
  occurrence later than `window_started_at + 1h` starts a new window. It answers "how hot is it
  now" without a warehouse query. The full timeline is a bucketed query on the occurrence
  dataset.
- **Samples** are bounded maps in `samples`: top 10 process names with counts, the 5 latest
  distinct command lines, top 10 images, top 20 nodes with counts, top 5 users, the 5 latest
  occurrence ids. Each list is capped at insert; nothing grows with occurrence volume. Samples
  outlive the occurrences they came from, so a finding stays explainable after occurrence
  retention expires.
- **Counting semantics.** Occurrence rows are idempotent on their id. The finding upsert is the
  last write before ACK, so a redelivery counts twice only if the process dies between the CNPG
  commit and the JetStream ACK. Finding counts are therefore at-least-once inside that window,
  and the authoritative count is a query on the occurrence dataset. An id-receipt ledger
  (one CNPG row per occurrence, pruned like `StatefulEvaluationLedger`) would make counts exact;
  it is not adopted without the user's agreement, because it adds a per-occurrence CNPG write for
  a failure window of one commit-to-ACK gap (open question 2).

### Decision 5: Occurrences are a new telemetry dataset, on exactly one backend

`runtime_security_occurrences` is append-only telemetry, so it follows the hard rule. With
StarRocks enabled it is written to and read from the warehouse only. With StarRocks disabled it
is written to and read from a CNPG hypertable. It is never written to both, and the CNPG table,
writer and reader stay for installations without StarRocks.

- **Why not keep `ocsf_events`.** Falco bursts in the shared event table are what flood the Events
  page, `in:security_findings` and the alert engine. Typed columns are needed for the SRQL
  filters, and the raw payload needs a column that is never truncated (the warehouse `events` row
  has none). Removing Falco occurrences from `ocsf_events` leaves it carrying only the
  low-volume lifecycle transitions (Decision 7).
- **Typed columns:** `id`, `time`, `finding_uid`, `rule`, `rule_source`, `priority`,
  `severity_id`, `partition`, `cluster_id`, `hostname`, `device_uid`, `node_device_uid`,
  `binding_status`, `entity_kind`, `namespace`, `owner_kind`, `owner_name`, `pod_name`,
  `container_id`, `container_name`, `image_repository`, `image_tag`, `image_digest`,
  `process_name`, `process_exe`, `process_cmdline`, `process_cwd`, `process_pid`, `parent_name`,
  `user_name`, `user_uid`, `evt_type`, `fd_name`, `src_ip`, `src_port`, `dst_ip`, `dst_port`,
  `l4_proto`, `tactics`, `techniques`, `attribution_status`, `falco_uuid`, `ingest_subject`,
  `ingest_path` (`direct` or `log_promotion`), `raw_payload`, `raw_sha256`, `raw_bytes`,
  `evidence_status` (`stored` or `oversize`).
- **Raw evidence is byte-exact.** `raw_payload` holds the exact bytes received (or, on the log
  path, the canonical JSON of the Falco record). CNPG uses `text`. The warehouse column is
  `VARCHAR(1048576)`, the StarRocks maximum, which equals the NATS default `max_payload` the chart
  does not override, so a direct-path message always fits. A record that exceeds the column is
  never truncated: it is stored with `raw_payload = NULL`, its digest and length, and
  `evidence_status = oversize`, counted in telemetry, and raised as a health event. This cannot
  happen on the direct path with the shipped NATS settings. It is documented rather than built
  around.
- **Occurrence id.** Derived from the Falco `uuid` when present (as today), otherwise from the
  raw bytes. Both ingest paths derive it the same way, so a record that reaches both paths is one
  occurrence.
- **Writes.** The occurrence load happens before the finding upsert. A failed load fails the
  batch and JetStream redelivers it; no finding is updated for an occurrence that was not stored.
- **No duplicate `logs` row.** The direct processor stops writing a `logs` row per Falco event.
  The occurrence row is the evidence record. Log-path Falco records keep their native `logs` row,
  because that is the record they arrived as.

### Decision 6: Lifecycle

- `active` -> `resolved` automatically after a quiet period with no occurrence (default 24 h,
  setting `runtime_findings.auto_resolve_after`), or when an operator resolves it.
- `resolved` -> `active` on a new occurrence (`reopen_count += 1`, a new episode starts and
  `episode_occurrence_count` and episode severity reset).
- `active` -> `suppressed` by an operator, with an optional expiry and a reason. A suppressed
  finding keeps counting and sampling but emits no alerting transitions. At expiry it returns
  to `active` if occurrences continued, otherwise to `resolved`.
- The auto-resolve sweep is a periodic Oban job over a bounded page, ordered by `last_seen`.

### Decision 7: Alerts are driven by lifecycle transitions through an outbox

- **Transitions:** `opened` (first occurrence), `reopened`, `escalated` (episode severity rose),
  `resolved`. Each draws the next `transition_seq` for the finding inside the finding transaction
  and inserts an outbox row in the same transaction.
- **Relay.** The outbox relay writes each transition as an OCSF Detection Finding event (activity
  Create, Update or Close) to `ocsf_events` through the normal event destination, then admits it
  through `StatefulAlertEngine.evaluate_events/1`, then deletes the outbox row. The event id is
  `deterministic_uuid(finding_uid <> ":" <> transition_seq)`, so a replayed relay is idempotent at
  the event store and the engine's replay rejection.
- **Why an outbox.** Computing transitions from the upsert result and emitting them after commit
  would lose `opened` if the process died in between: the redelivered batch finds the finding
  already active and computes no transition. That is the alert operators most need.
- **Event shape.** `log_name = "falco.finding." <> transition`, `log_provider = "serviceradar.core"`,
  severity = the finding's episode severity, `device.uid` = the finding's `device_uid` (so
  `add-alert-device-identity` ties the alert to the device), `metadata.finding_info.uid`, and a
  bounded `metadata.runtime_finding` summary built from the finding (entity, binding, counts,
  window, samples, latest occurrence ids). That summary is what the alert detail renders; it
  satisfies the diagnostic-summary contract of `update-falco-alert-diagnostics` without reading
  occurrences.
- **Managed rule `falco_runtime_finding` (template v1):** `signal: :event`,
  `match: %{"subject_prefix" => "falco.finding.", "attribute_equals" =>
  %{"runtime_finding.transition" => ["opened", "reopened", "escalated"]}, "severity_number_min" => 5,
  "recovery" => %{"subject_prefix" => "falco.finding.resolved"}}`, `group_by:
  ["finding_info.uid"]`, threshold 1, cooldown 300 s, renotify 21,600 s, title template
  `"{runtime_finding.rule} on {runtime_finding.entity_name}"`. The group key is the finding uid,
  which is stable; descriptive values go in the title, never in `group_by`.
- **Volume.** Admissions are bounded by distinct findings times transitions, not by event rate.
  A 10,000-event burst from one DaemonSet on 20 nodes is one `opened` transition.
- **Occurrences are no longer alert inputs.** `FalcoEvents` stops calling
  `StatefulEvaluationLedger.evaluate_once/1` for occurrences.

### Decision 8: Retiring `falco_critical_incident`

- `RuleSeeder` gains `@retired_stateful_rules %{"falco_critical_incident" => 1}` (name to last
  shipped template version) and stops creating it.
- On boot, a retired rule that is `managed: true` with a fingerprint equal to the last shipped
  template is set `enabled: false` and stamped `retired_at`. Its active alerts are resolved with
  reason `superseded_by_runtime_findings`, which links to `/security/runtime-findings`. The rule
  is disabled rather than deleted, so alert history that names it still resolves.
- An operator-modified managed copy or an unmanaged rule with the same name is not touched. The
  seeder logs it once per boot, and the Rules settings page flags it as "matches retired Falco
  occurrence input". Its `subject_prefix "falco."` still matches the new `falco.finding.*`
  transitions, so such a rule degrades to one alert per transition instead of going silent.
- The prefix choice for transitions is deliberate: it keeps a customized legacy rule useful.

### Decision 9: Transport stays on NATS; the normalizer is transport-independent

The edge-record pipeline (`move-agent-telemetry-to-edge-records`, `ServiceRadar.Edge.ContractCatalog`)
is not adopted for Falco in this change.

- **It is an agent-producer contract.** Edge records require an agent spool, a standing output
  grant signed per (agent, contract, epoch), and gateway authorization. Falcosidekick is a
  third-party process with none of these, and Falco is not an agent producer. Adopting it means
  building an agent-hosted Falco receiver (Falco HTTP or gRPC output to a local agent endpoint),
  a new typed contract, and a projector: a new agent capability, not a storage fix.
- **It does not address the problem the user raised.** The problem is the shape of the data and
  its path through the alert engine. The admission-side loss is being fixed separately.
- **What would justify it later:** publisher-side durability (Falcosidekick's NATS output gets no
  JetStream PubAck, so events published while NATS is unreachable are lost at the publisher), and
  a signed producer identity, which would make node binding `agent`-strength by construction.
- **Keeping the door open.** The normalizer takes a decoded Falco record plus ingest metadata
  (`subject`, `received_at`, `ingest_path`, optional `agent_id`) and returns occurrence rows and
  finding deltas. A future `serviceradar.runtime_security.falco_event` contract projector calls
  the same function.
- **Leaf subject mismatch.** `NatsLeafConfigGenerator` allows `events.falco.>` while
  `NatsLeafCredentials` and the chart allow `falco.>`. Implementation verifies which one edge
  Falcosidekick packages use and aligns the other.

### Decision 10: SRQL entities

- `in:runtime_findings` (aliases `runtime_finding`, `falco_findings`) reads
  `ocsf_findings JOIN runtime_finding_details` in CNPG on both backends, because findings are
  current state. Filters: `status`, `severity`, `rule`, `priority`, `entity_kind`, `cluster`,
  `namespace`, `owner_kind`, `owner`, `pod`, `hostname`, `device_uid`, `node_device_uid`,
  `binding_status`, `attribution`, `tactic`, `technique`, `first_seen`, `last_seen`, `time:`
  (matches `last_seen`), `finding_uid`. Default sort `last_seen:desc`. Stats over `count()`
  grouped by rule, namespace, owner, device.
- `in:runtime_security_occurrences` (alias `runtime_occurrences`) reads the active telemetry
  backend. Its filters are the typed columns of Decision 5. `raw_payload` is returned only when
  selected explicitly or on single-row detail, never in list projections.
- When `add-ocsf-finding-model` moves `in:security_findings` onto `ocsf_findings`, Falco findings
  appear there through the common columns; `in:runtime_findings` remains the typed view.
- The occurrence reader needs a CNPG and a warehouse implementation, and the parity harness of
  `extend-starrocks-to-all-telemetry` Decision 2 gates the warehouse reader.

### Decision 11: Retention

| Data | Store | Retention |
| --- | --- | --- |
| Active and suppressed findings | CNPG | kept while active or suppressed |
| Resolved findings | CNPG | deleted `runtime_findings.resolved_retention` after `last_resolved_at` (default 90 days), by a bounded prune job |
| Occurrences | StarRocks or CNPG | the dataset's telemetry retention: warehouse per-dataset retention when StarRocks is enabled, a CNPG hypertable retention policy otherwise |
| Transition events | `ocsf_events` | event retention, unchanged |
| Outbox rows | CNPG | deleted on relay; age monitored |

Deleting a finding does not delete its occurrences; they age out on their own clock.

### Decision 12: UI

- **Device page, Runtime security tab.** Findings where `device_uid` or `node_device_uid` is this
  device, active first, then by severity and `last_seen`. Each row shows rule, subject (host or
  workload), status, severity, counts, last seen, and binding method. Loads only after the socket
  connects, paginates through SRQL, and uses streams.
- **`/security` Runtime findings view.** Filters by cluster, namespace, owner, rule, status and
  binding; groups by workload; includes an "Unbound" filter showing ambiguous and unbound
  findings with their candidate count.
- **Finding detail `/security/runtime-findings/:uid`.** Subject and binding (with method,
  ambiguity, and a device link when bound), attribution status, samples, an occurrence timeline
  (bucketed counts from `in:runtime_security_occurrences`), the latest occurrences with typed
  fields, a raw-evidence viewer per occurrence, lifecycle history from transitions, and resolve /
  suppress actions behind RBAC.
- **Alert detail** links to the finding detail when the alert's event carries
  `finding_info.uid`.
- **`security-findings` dashboard package.** Falco frames move to `in:runtime_findings`.

## Migration Plan

1. CNPG migrations: `ocsf_findings` (if absent), `runtime_finding_details`, the transition outbox,
   and the `runtime_security_occurrences` hypertable with its retention policy. StarRocks
   migration: `serviceradar.runtime_security_occurrences`, partitioned by day and keyed on
   `(time, id)`.
2. Deploy EventWriter, core and web-ng together. From then on Falco occurrences go to the new
   dataset and findings, and no longer to `ocsf_events`, `logs` (direct path) or the alert engine.
3. The seeder creates `falco_runtime_finding` and retires `falco_critical_incident` (Decision 8).
4. Forward-only. Findings start at the first occurrence after upgrade. Historical Falco rows in
   `ocsf_events` and `logs` stay readable in Events and Logs until retention removes them.
   Release notes say so, and name the replacement queries.
5. Existing Falcosidekick collector packages keep working without the new custom fields
   (cluster id `default`, partition from the package). Regenerating the bundle adds them.
6. Rollback: disabling the new code path is a release rollback. Findings and occurrences
   written in the meantime remain; the retired rule must be re-enabled by hand, and release notes
   say so.

## Risks / Trade-offs

- **Pod-level findings split on rollout when no owner is known.** Mitigation: owner from Falco
  metadata fields or workload identity; the UI groups pod-level findings by namespace and shows
  that the owner is missing. Accepted over a heuristic that can merge unrelated workloads.
- **At-least-once finding counts** in the commit-to-ACK window (Decision 4). The occurrence
  dataset is exact.
- **Operators lose Falco rows in Events and Logs.** Mitigation: release notes, a "Runtime
  findings" link where the Falco source filter used to be, and the occurrence entity.
- **Hostname reuse across sites.** Handled as `ambiguous`, never silently bound; partition and
  cluster in the entity key limit collisions.
- **New telemetry dataset cost.** One more dataset in both backends, with a warehouse reader to
  parity-test. Accepted to get typed filters and untruncated evidence.

## Open Questions

1. Should the direct processor really stop writing the per-event `logs` row (Decision 5), or keep
   it for operators who search Falco text on the Logs page?
2. Are at-least-once finding counts acceptable, or should an id-receipt ledger make them exact
   (one small CNPG row per occurrence, pruned after the replay horizon)?
3. Should "N occurrences in a window" alerting be offered as a transition (for example
   `escalated` when `window_count` crosses a threshold), or is lifecycle alerting enough?
4. Auto-resolve quiet period: is 24 h the right default for runtime detections?
5. Is a bounded backfill (for example the last 7 days of Falco `ocsf_events` on CNPG-only
   installs) worth building, or is forward-only acceptable?
6. Should this change land first and create `ocsf_findings`, or wait for `add-ocsf-finding-model`
   section 1?
7. When a future agent-hosted Falco receiver exists, should Falcosidekick ingestion move to the
   edge-record pipeline (Decision 9)?
