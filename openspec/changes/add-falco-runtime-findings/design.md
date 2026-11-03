# Design: Falco runtime findings

Tracking epic: #6271 ("Falco transport" item).

## Context

### Ingestion today

- **NATS path.** Falco posts to Falcosidekick. Falcosidekick's NATS output publishes to `falco.>`
  subjects; the chart grants the `serviceradar-falcosidekick` identity `falco.>`, and edge leaf
  credentials allow `falco.>` while `NatsLeafConfigGenerator` allows `events.falco.>`. JetStream
  stream `events` captures the subject, and the EventWriter pipeline routes any `falco` /
  `falco.*` subject to `ServiceRadar.EventWriter.Processors.FalcoEvents` (consumer `FALCO`,
  batch 100). The `:falcosidekick` collector package type provisions NATS credentials for remote
  Falcosidekick installs.
- **Log path.** A Falco record that arrives as a log is stored by the `Logs` processor, and an
  EventRule (for example `copyfail_falco_logs_to_security_events`) can promote it, decorated by
  `LogPromotion.enrich_falco_event/3`.
- **Shared decomposition.** `ServiceRadar.EventWriter.FalcoDecomposition` extracts context,
  diagnostics (process, parent, user, file, network, container, Kubernetes), MITRE `attacks`,
  observables, an attribution status, and a `finding_info` whose uid hashes
  `{rule, source, subject, class_uid, hostname, namespace, pod, container_id}`.
- **Per event, FalcoEvents writes** a `logs` row with the whole payload, an `ocsf_events` row with
  `message = output`, `unmapped = payload` and `raw_data`, both through
  `Destination.persist_after_cnpg/3`, then admits every row into `StatefulAlertEngine` through
  `StatefulEvaluationLedger.evaluate_once/1`.
- **Alerting.** The managed rule `falco_critical_incident` (template v1) matches `log_name`
  prefix `falco.` at severity >= Critical with `group_by: ["rule", "hostname"]`.
- **Device correlation.** `DeviceCorrelation.resolve/1` tries the explicit uid, the agent id
  (including an inferred `agent-<hostname>`), `platform.workload_identity_current`, IP, then
  hostname, and on a shared hostname takes the first device by sort order.
- **Warehouse widths.** `ServiceRadar.Analytics.StarRocks.Rows` truncates the event `message` to
  65,533 bytes and drops document columns over 1,048,576 bytes; the warehouse `events` table has
  no `raw_data` column; `logs.body` is `VARCHAR(65533)` with no guard; BMP, OTel span and flow
  attribution columns are also truncated to their widths.

### The agent edge spool

The agent commits a record to its edge spool under a granted contract before the record leaves
the node. The gateway authorizes by contract and does not decode the payload. A projector
registered by `{contract_id, contract_version}` decodes and projects. One edge record is at most
512 KiB (`MaxRecordBytes`). The otel-collector add-on and `{"serviceradar.otlp.relay", 1}` are a
different producer. This change does not use them.

### Why this path does not use the OTLP relay contract

Falco's native `http_output` posts one JSON event per request. With `json_output`,
`json_include_output_fields_property`, and `json_include_tags_property` enabled, that JSON
contains `output_fields`, `tags`, and `uuid` (Decision 9). The OTLP relay contract
`{"serviceradar.otlp.relay", 1}` carries one OTLP record per edge record and refuses a record
above the 512 KiB bound back to the sender. Putting the Falco JSON inside an OTLP log would be
a second encoding, and that contract cannot split an event into parts. This change therefore
uses a Falco contract and chunks on the agent. Falcosidekick is not in the path, and its OTLP
logs output is not extended.

## Goals / Non-Goals

- Goals: one actionable record per (entity, rule); every finding tied to an inventory device or
  Kubernetes workload, or explicitly marked as not tied; alert volume proportional to distinct
  findings; raw evidence retained losslessly and never truncated or dropped; Falco on the durable
  edge-record pipeline from day one with no long-lived second path; storage that follows the
  JetStream-first and one-backend rules.
- Non-Goals: the generic alert-admission no-loss fix; changing Falco rules or priorities;
  rule-level suppression policies; mapping Falco plugin sources to their native subjects;
  Trivy and endpoint-inventory mapping onto `ocsf_findings` (still owned by
  `add-ocsf-finding-model`); a Kubernetes workload inventory page; volume or rate alerting.

## Decisions

### Decision 1: This change creates the shared `platform.ocsf_findings` table

Agreed sequencing: this change lands first and creates `platform.ocsf_findings` with the schema
`add-ocsf-finding-model` plans, so neither change blocks the other. That change then adds its
other producers to the existing table instead of creating it. Its tasks 1.1 and 1.2 (table and
event reference column) and its Falco tasks 2.3, 2.4 and 3.1 are delivered here; both changes
record this.

- **Common table (`ocsf_findings`), per `add-ocsf-finding-model` Decision 1:** `uid` (PK, the
  `finding_info.uid`), `class_uid`, `category_uid`, `type_uid`, `activity_id`, `status_id`
  (OCSF finding status: 1 New, 2 In Progress, 3 Suppressed, 4 Resolved), `severity_id`,
  `confidence_id`, `risk_score`, `source`, `title`, `entity_kind`, `entity_uid`, `device_uid`,
  `first_seen`, `last_seen`, `occurrence_count`, `payload` (full OCSF finding JSONB),
  `class_payload` (class-specific JSONB), `inserted_at`, `updated_at`. Falco findings use class
  2004 and `source = 'falco'`.
- **Event reference.** `finding_info_uid` is added to CNPG `ocsf_events` and warehouse `events`
  so lifecycle transition events (Decision 7) can be drilled into without JSON parsing.
- **Runtime extension (`platform.runtime_finding_details`, 1:1 on `finding_uid`,
  `ON DELETE CASCADE`):** `rule`, `rule_source`, `priority`, `entity_key`, `cluster_id`,
  `partition`, `namespace`, `owner_kind`, `owner_name`, `pod_name`, `hostname`, `binding_status`,
  `binding_method`, `binding_candidates`, `node_device_uid`, `node_binding_status`,
  `attribution_status`, `tactics text[]`, `techniques text[]`, `episode_started_at`,
  `episode_occurrence_count`, `episode_severity_id`, `reopen_count`, `window_started_at`,
  `window_count`, `samples jsonb` (bounded, Decision 4), `first_occurrence_id`,
  `latest_occurrence_id`, `last_resolved_at`, `transition_seq`.
- Runtime attributes stay off the cross-class table; typed columns give indexed SRQL filters.

### Decision 2: The subject entity is the most specific stable one

| `entity_kind` | When | `entity_key` coordinates |
| --- | --- | --- |
| `k8s_workload` | namespace, owner kind and owner name are known | `partition / cluster_id / namespace / owner_kind / owner_name` |
| `k8s_pod` | namespace and pod are known, owner is not | `partition / cluster_id / namespace / pod_name` |
| `host` | a `syscall` event with no pod context (bare host, Docker host, nested runtime) | `partition / normalized hostname` |
| `falco_source` | a non-`syscall` source (plugin events) | `partition / rule_source / normalized hostname` |

- **Owner sources:** owner fields Falco emits through its Kubernetes metadata plugin or custom
  fields, then owner fields on the matching `workload_identity_current` row once
  `add-workload-identity-enrichment` adds owner chains. No owner is inferred by parsing pod names:
  a guessed owner can merge unrelated workloads silently. A pod-level finding records
  `attribution_status = partial`.
- **Container-only events** are first enriched from `workload_identity_current` by
  `(partition, container_id)` (`attribution_status = enriched`). Otherwise the subject is the
  `host`, with container id and image as occurrence attributes and finding samples.
- **Partition** is the attested partition of the edge record (Decision 9). **Cluster id** is the
  value the agent stamps from `falcoIngest.clusterId`, defaulting to `default`. It is a key
  within the attested partition. Two partitions that both use cluster id `default` therefore
  produce different workload and pod keys, and different finding uids.
- **Finding uid** = `deterministic_uuid("falco:runtime-finding:v1:" <> entity_kind <> "|" <>
  entity_key <> "|" <> rule)`. It never includes container id, pod uid, device uid or the ingest
  subject, so a binding can arrive, change or follow a DIRE merge without changing the finding.
- **Rule identity** is the Falco rule name. A renamed rule is a new finding.

### Decision 3: Inventory binding records how it was made, and never guesses

`DeviceCorrelation` is extended to return `{device_uid | nil, method, candidates}`. The same
resolution runs for the subject (`device_uid`) and for the node the occurrence ran on
(`node_device_uid`).

- **Methods, strongest first:** `explicit_uid`; `agent` (an agent id that exists, including the
  accepting agent when the record's hostname is that agent's own host); `workload_identity`;
  `k8s_node` (node name to `k8s_nodes_current.internal_ip`, then to a device by IP in the
  partition); `hostname_unique`.
- **The accepting agent is provenance, not location.** In a cluster one agent accepts events for
  every node, so the agent id binds a record to its host only when the record's hostname is that
  agent's own host.
- **Ambiguity is a state.** A hostname matching more than one non-deleted device yields
  `binding_status = ambiguous` with `binding_candidates = n` and no device for that lookup.
  Subject and node are separate lookups. An ambiguous subject still appears on the device page
  of a bound node.
- **Unbound is a state.** No candidate yields `unbound`. The finding is created and listed under
  unbound findings. It appears on a device page only when its subject or its node is bound to
  that device.
- **Re-resolution.** A bounded periodic job retries `unbound`, `ambiguous`, and bindings to devices
  that are now deleted or merged, following the canonical device, in pages ordered by `last_seen`.
- **Occurrences keep their ingest-time binding**; the finding carries the current one.
- **Falco is not an inventory source.** Binding never creates, merges, restores or revives
  devices, and never contributes identity facts.

### Decision 4: Aggregation is per batch, atomic per finding, with bounded samples

- Occurrences of a batch are grouped by finding uid; one upsert per finding, in one CNPG
  transaction that locks findings in uid order (no deadlocks between EventWriter replicas). It
  adds to `occurrence_count` and `episode_occurrence_count`, moves `first_seen` / `last_seen`
  monotonically, raises episode severity monotonically, and merges samples.
- **Window:** `window_started_at` / `window_count` is a tumbling one-hour window for "how hot is it
  now". It is a display counter, not an alert input. The full timeline is a bucketed query on the
  occurrence dataset.
- **Samples** (in `samples`), capped at insert: top 10 process names with counts, 5 latest distinct
  command lines, top 10 images, top 20 nodes with counts, top 5 users, 5 latest occurrence ids.
  Samples outlive the occurrences they came from.
- **Counts are at-least-once** (user decision). Occurrence rows are idempotent on their id, and the
  finding upsert is the last write before ACK, so a count can be inflated only if the process
  stops between the CNPG commit and the JetStream ACK. The occurrence dataset is the exact count.
  No per-occurrence receipt ledger is added.

### Decision 5: Occurrences are a new telemetry dataset, on exactly one backend

`runtime_security_occurrences` is append-only telemetry. With StarRocks enabled it is written to
and read from the warehouse only; with StarRocks disabled, a CNPG hypertable. Never both. The CNPG
table, writer and reader stay for installations without StarRocks.

- **Why not `ocsf_events`.** Falco bursts in the shared event table flood the Events page,
  `in:security_findings` and the alert engine; typed columns and an untruncated evidence column
  are needed. `ocsf_events` keeps only the low-volume lifecycle transitions (Decision 7).
- **Typed columns:** `id`, `time`, `finding_uid`, `rule`, `rule_source`, `priority`,
  `severity_id`, `partition`, `cluster_id`, `relay_agent_id`, `hostname`, `device_uid`,
  `node_device_uid`, `binding_status`, `entity_kind`, `namespace`, `owner_kind`, `owner_name`,
  `pod_name`, `container_id`, `container_name`, `image_repository`, `image_tag`, `image_digest`,
  `process_name`, `process_exe`, `process_cmdline`, `process_cwd`, `process_pid`, `parent_name`,
  `user_name`, `user_uid`, `evt_type`, `fd_name`, `src_ip`, `src_port`, `dst_ip`, `dst_port`,
  `l4_proto`, `tactics`, `techniques`, `attribution_status`, `falco_uuid`, `edge_event_id`,
  `raw_payload`, `raw_ref`, `raw_sha256`, `raw_bytes`, `raw_storage` (`inline` or
  `object_store`).
- **Occurrence id** is derived from the JSON `uuid` when present, otherwise from the digest of
  the raw JSON.
- **Write order:** spilled raw objects (Decision 6), then the occurrence load, then the finding
  upsert and transition outbox. A failure at any step fails the batch and JetStream redelivers it.
- **No generic `logs` row** (user decision). A recognized Falco record is not written to `logs`;
  the occurrence holds the raw record and is queryable through SRQL.
- **Free-text column widths.** In the warehouse, `process_cmdline`, `fd_name` and the other
  free-text columns are `VARCHAR(1048576)`, so no typed column is ever cut. The full record is
  always in the raw evidence.

### Decision 6: Raw evidence is lossless; large records go out-of-line, never cut

- **What raw evidence is.** The raw record is the JSON body Falco posted, unchanged. `raw_payload`
  stores those bytes; `raw_sha256` and `raw_bytes` describe them.
- **Inline threshold** is 1,048,576 bytes on both backends: the StarRocks `VARCHAR` maximum, used
  on CNPG too so readers behave the same everywhere and CNPG rows stay bounded.
- **Above the threshold** the bytes are uploaded to the ServiceRadar datasvc object store, the same
  store and upload path as endpoint inventory artifacts (`Proto.ObjectMetadata` with SHA-256),
  before the occurrence row is written. The occurrence stores `raw_payload = NULL`,
  `raw_storage = object_store`, and `raw_ref`:
  `{"store": "datasvc_object_store", "key": "runtime-security/raw/<yyyy-mm-dd>/<occurrence_id>.json",
  "sha256": "<hex>", "bytes": <n>, "content_type": "application/json"}`. The date is the
  occurrence's UTC `time` date.
- **Nothing is dropped.** An upload that fails (including a full bucket, which the store refuses
  rather than evicts) fails the batch; JetStream redelivers and the upload is retried under the
  same key. The failure is counted and raised as a health event. There is no "mark oversize and
  continue" path.
- **Retention coupling.** An object lives exactly as long as the occurrence that references it. The
  occurrence dataset is day-partitioned on both backends, and the object key carries the same UTC
  day. `ServiceRadar.ObjectStore.RetentionWorker` gains a runtime-evidence pass that deletes a day
  prefix only after that day's occurrence partition (warehouse) or chunk (CNPG) has been dropped
  on the active backend, plus a one-day grace. It never deletes a day that is still retained.
  Objects uploaded for a batch that was never stored (it reached `max_deliver`) are removed with
  their day.
- **Reads.** SRQL returns `raw_ref` for spilled records. The finding detail page streams the object
  through core and verifies the digest; a missing object or digest mismatch is displayed and raised
  as a health event, never shown as empty.
- **Events larger than one edge record.** The agent chunks the posted JSON before the spool
  (Decision 9). The projector reassembles it before this threshold is applied, so a 600 KiB event
  is stored inline and a 1.5 MB event is stored out-of-line. Size never refuses or drops the event.

### Decision 7: Lifecycle and alerting

- `active` -> `resolved` automatically after a quiet period with no new occurrence (default 24 h,
  configurable as `runtime_findings.auto_resolve_after`), or by an operator.
- `resolved` -> `active` on a new occurrence (`reopen_count += 1`, a new episode starts).
- **Alerting is lifecycle only** (user decision): `opened`, `reopened`, `escalated` (episode
  severity rose), `resolved`. There is no volume or rate alert. Falco findings are `active` or
  `resolved`. They do not write the shared table's suppressed status.
- Each transition draws the next `transition_seq` inside the finding transaction and inserts an
  outbox row in that transaction. A relay writes it as an OCSF Detection Finding event (activity
  Create, Update or Close) to `ocsf_events`, admits it through
  `StatefulAlertEngine.evaluate_events/1`, then deletes the outbox row. Event id =
  `deterministic_uuid(finding_uid <> ":" <> transition_seq)`, so a replay is idempotent. Without
  the outbox, a crash after commit would lose `opened`, because the redelivered batch finds the
  finding already active.
- **Event shape:** `log_name = "falco.finding." <> transition`, `log_provider =
  "serviceradar.core"`, episode severity, `device.uid` = the finding's `device_uid`,
  `finding_info_uid`, and a bounded `metadata.runtime_finding` summary (entity, binding, counts,
  window, samples, latest occurrence ids). That summary satisfies the diagnostic-summary contract
  of `update-falco-alert-diagnostics`.
- **Managed rule `falco_runtime_finding` (template v1):** `signal: :event`; match
  `subject_prefix "falco.finding."`, `runtime_finding.transition in [opened, reopened, escalated]`,
  `severity_number_min 5`; recovery on `subject_prefix "falco.finding.resolved"`; `group_by
  ["finding_info.uid"]`; threshold 1; cooldown 300 s; renotify 21,600 s; title
  `"{runtime_finding.rule} on {runtime_finding.entity_name}"`.
- Occurrences are never alert inputs. A 10,000-event burst from one DaemonSet is one `opened`.

### Decision 8: Retiring `falco_critical_incident`

- `RuleSeeder` gains `@retired_stateful_rules %{"falco_critical_incident" => 1}` and stops creating
  it. A managed copy whose fingerprint equals template v1 is disabled and stamped `retired_at`;
  its active alerts are resolved with reason `superseded_by_runtime_findings`. Disabled, not
  deleted, so alert history still resolves.
- An operator-modified or unmanaged copy is not touched, is logged once per boot, and is flagged in
  Rules settings. Its `subject_prefix "falco."` still matches `falco.finding.*` transitions, so it
  degrades to one alert per transition rather than going silent.
- The seeded EventRule `copyfail_falco_logs_to_security_events` matches Falco logs on `falco.`
  subjects, which no longer exist once Falco records stop being written as logs. It is removed
  from the seeded defaults and a pristine copy is disabled the same way. Its rule becomes an
  ordinary runtime finding with the Falco priority.

### Decision 9: Falco posts JSON to the agent, which spools a Falco edge contract

Falco reaches ServiceRadar only through the agent's edge spool. The NATS `falco.*` path is
removed in the same rollout. Falcosidekick is not in the path, and no Falcosidekick fork is
required.

**Path:** Falco DaemonSet `http_output` -> agent HTTPS `POST /v1/falco/events` -> parts under
`{"serviceradar.falco.event", 1}` in the agent edge spool -> gateway -> Falco projector
(reassemble, then normalize). The normalizer does not read `logs.otel`. A Falco-shaped log on
`logs.otel` stays an ordinary log and creates no finding.

**Why this contract.** The posted body is the Falco JSON event. `json_output: true` with
`json_include_output_fields_property: true` and `json_include_tags_property: true` includes
`output_fields`, `tags`, and `uuid`. The OTLP relay contract refuses one record above 512 KiB
and would wrap that JSON in another encoding. The Falco contract carries the posted bytes. The
agent splits an event that does not fit in one 512 KiB edge record into ordered parts:

- `falco_event_id` is the JSON `uuid` when present, otherwise the SHA-256 of the full JSON;
- `part_index` is 0-based and `part_total` is the count; a small event is part 0 of 1;
- each part's payload is a contiguous slice of the posted JSON, and the encoded edge record stays
  within 512 KiB;
- every part carries `raw_sha256` and `raw_bytes` of the full JSON, plus the agent-stamped
  `cluster_id`;
- the edge-record event id is derived from `falco_event_id` and `part_index`, so redelivery
  dedupes that part only.

The projector concatenates a complete set in index order, checks the digest, and only then
normalizes. It does not discard a part and does not acknowledge any part until the occurrence
and finding update are stored. An incomplete set produces no occurrence. After reassembly,
Decision 6 applies: inline up to 1 MiB, object store above that. Nothing is refused or dropped
for size.

**Endpoint auth.** Falco's `http_output` supports `mtls`, `client_cert`, `client_key`, and
`ca_cert`. It has no custom-header token. The agent already authenticates callers with
chart-issued mTLS certificates, so the endpoint requires that client certificate. A bearer token
is the otel-collector add-on's convention and is not used. Loopback-only binding is not used
either: the agent is one Deployment and Falco is a DaemonSet, so the DaemonSet posts to the
agent Service. `compress_uploads` is false, and the stored raw bytes are the posted JSON.

**Chart wiring (ServiceRadar chart):**

- `falcoIngest.enabled` (default `false`), `falcoIngest.clusterId` (default `default`),
  `falcoIngest.namespace` (the Falco DaemonSet namespace; default the release namespace),
  `agent.falcoReceiver.port` (default `14318`).
- When enabled: the `serviceradar-agent` Service exposes `falco-https` on that port; core seeds
  the registry entry `{"serviceradar.falco.event", 1}` and the agent's grant; the chart renders
  the client certificate, client key, and CA in `falcoIngest.namespace`, plus the Falco settings
  for `json_output`, the two include flags, and `http_output` (`enabled`, the agent URL,
  `mtls: true`, `compress_uploads: false`, and the certificate paths). The network policy admits
  `falcoIngest.namespace` to that port. The agent stamps `falcoIngest.clusterId` onto each
  event. The attested partition is the agent's own edge-record partition.
- No Falcosidekick NATS user, no OTLP ingestion token, and no `otel-collector` add-on assignment
  for this path. Falcosidekick collector packages stop receiving NATS credentials and do not gain
  an OTLP configuration.

**Normalizer input.** The projector hands the reassembled JSON object to the normalizer. Rule,
priority, source, hostname, time, tags, uuid, and `output_fields` are read from that object.
The partition is the attested partition on the edge record, not a field of the JSON.

**Removal in the same rollout (per-producer cutoff).** The release that ships this path removes:
the `FALCO` consumer and `Processors.FalcoEvents` (`config.ex`, both `runtime.exs` files), the
pipeline's `falco` routing, `falco.>` from the chart NATS permissions and leaf credentials,
`events.falco.>` from `NatsLeafConfigGenerator`, the `serviceradar-falcosidekick` NATS user and
its certificate generation, and NATS credentials on Falcosidekick collector packages (existing
ones are revoked). Release notes require pointing the Falco DaemonSet `http_output` at the agent
in that upgrade. An unmigrated NATS publisher is refused. There is no flag that keeps both paths.

**Delivery confirmation (task 0.4).** The agent returns HTTP success only after every part is in
its durable edge spool. Each part stays there until its JetStream PubAck, and the projector
stores the reassembled event before acknowledging the parts. A spool admission failure is a
non-success HTTP response, so the agent has not accepted an event it cannot hold.

### Decision 10: SRQL entities

- `in:runtime_findings` reads `ocsf_findings JOIN runtime_finding_details` in CNPG on both
  backends. Filters: `status`, `severity`, `rule`, `priority`, `entity_kind`, `partition`,
  `cluster`, `namespace`, `owner_kind`, `owner`, `pod`, `hostname`, `device_uid`,
  `node_device_uid`, `binding_status`, `attribution`, `tactic`, `technique`, `first_seen`,
  `last_seen`, `time:` (on `last_seen`), `finding_uid`. Default sort `last_seen:desc`; stats
  counts by rule, namespace, owner, device.
- `in:runtime_security_occurrences` reads the active telemetry
  backend with the typed columns of Decision 5. `raw_payload` and `raw_ref` are returned only when
  selected or on single-row detail.
- When `add-ocsf-finding-model` moves `in:security_findings` onto `ocsf_findings`, Falco findings
  appear there through the common columns.
- The occurrence reader has CNPG and warehouse implementations; the result-diff parity harness of
  `extend-starrocks-to-all-telemetry` Decision 2 gates the warehouse reader.

### Decision 11: Retention

| Data | Store | Retention |
| --- | --- | --- |
| Active findings | CNPG | kept while active |
| Resolved findings | CNPG | deleted `runtime_findings.resolved_retention` after `last_resolved_at` (default 90 days), bounded prune job |
| Occurrences | StarRocks or CNPG | dataset telemetry retention on the active backend |
| Spilled raw objects | datasvc object store | same day as their occurrence partition, plus one day (Decision 6) |
| Transition events | `ocsf_events` | event retention, unchanged |
| Outbox rows | CNPG | deleted on relay; age monitored |

Deleting a finding does not delete its occurrences.

### Decision 12: UI

- **Device page, Runtime security tab:** findings whose `device_uid` or `node_device_uid` is this
  device, active first, then by severity and `last_seen`; loaded after the socket connects, paged
  through SRQL, rendered with streams. An ambiguous subject does not hide a finding whose node is
  bound. A finding with neither a subject device nor a node device appears on no device page.
- **`/security` Runtime findings view:** filters by cluster, namespace, owner, rule, status and
  binding; grouped by workload; an Unbound filter for ambiguous and unbound findings.
- **Finding detail `/security/runtime-findings/:uid`:** subject and binding, attribution, samples,
  occurrence timeline, latest occurrences, raw evidence viewer (inline or streamed from the object
  store with digest check), lifecycle history, and an RBAC-gated resolve action.
- **Alert detail** links to the finding; the `security-findings` dashboard package moves its Falco
  frames to `in:runtime_findings`; Logs and Events point their Falco source filter at the view.

## Migration Plan

1. CNPG migrations: `ocsf_findings`, `finding_info_uid` on `ocsf_events`,
   `runtime_finding_details`, the transition outbox, the `runtime_security_occurrences` hypertable.
   StarRocks migrations: `runtime_security_occurrences`, `finding_info_uid` on `events`.
2. One release ships the Falco HTTP path and removes the NATS path (Decision 9).
3. The seeder creates `falco_runtime_finding` and retires `falco_critical_incident`.
4. **Forward-only, no backfill** (user decision). Findings start at the first accepted event.
   Historical Falco rows in `ocsf_events` and `logs` stay readable until retention removes them.
5. Operators point the Falco DaemonSet `http_output` at the agent during the upgrade (chart
   material in `falcoIngest.namespace`).
6. Rollback is a release rollback. The NATS path is gone in the new release, so rolling back also
   restores the previous Falco output configuration; release notes say so.

## Risks / Trade-offs

- **Cluster id is agent configuration.** `falcoIngest.clusterId` is stamped by the agent. The
  attested partition comes from the edge record. Falco's JSON supplies the workload fields.
- **One agent endpoint per cluster id.** A release that runs one in-cluster agent stamps one
  cluster id for every event that agent accepts.
- **Pod-level findings split on rollout** when no owner is known; accepted over a guessing
  heuristic.
- **At-least-once counts** in the commit-to-ACK window.
- **Operators lose Falco rows in Events and Logs**; release notes and replacement links cover it.
- **New telemetry dataset cost** in both backends, accepted for typed filters and lossless
  evidence.

## Open Questions

None. The user decided the logs row, count semantics, alerting scope, quiet period, oversize
handling, migration, sequencing, and transport on 2026-11-02 and 2026-11-03. The 2026-11-03
transport decision is Falco `http_output` into a chunked Falco edge contract, with the attested
partition in the workload uid, a bound node still showing the finding, and no operator
suppression or SRQL aliases.
