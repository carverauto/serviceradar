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

### The durable edge path this change moves onto

- The first-party `otel-collector` native add-on (`rust/otel-addon`, capability `otlp-relay:v1`)
  runs beside an agent. It serves OTLP/gRPC and OTLP/HTTP with optional TLS and token auth, holds
  accepted exports in a durable spool (`agent_forward`), and ships them to the agent as
  `OtlpRelayFrame`s over `RelayOtlp`.
- The agent commits each frame to its edge spool under the standing grant for contract
  `{"serviceradar.otlp.relay", 1}` (package `serviceradar.agent.otlp_relay`) before acking the
  add-on. The OTLP relay projector (`move-agent-telemetry-to-edge-records` task 4.1; contract text
  in #6262) re-checks the grant and republishes each `TelemetryRecord.payload` verbatim to the
  logs subject (`logs.otel` by default) with `Sr-Agent-Id`, `Sr-Partition` (the resolved
  partition slug), `Sr-Ingest-Identity = "agent:" <> origin_principal_id`, and `Nats-Msg-Id`
  set to the record's event id. It waits for the JetStream PubAck before the edge ledger commits.
- `logs.otel` is consumed by the EventWriter `Logs` processor.

### Falcosidekick's OTLP logs output, as it exists

Read from the Falcosidekick fork checkout in `~/src/falcosidekick` (`outputs/otlp_logs.go`):

- Configuration: `otlp.logs.endpoint`, `protocol` (`grpc`, `http/protobuf`, `http/json`),
  `timeout`, `headers`, `extraenvvars`, `minimumpriority`, `checkcert`; the matching environment
  variables are `OTLP_LOGS_*`.
- Each event becomes one log record through an `otelslog` logger: body = Falco `output`,
  attributes `priority`, `source`, `rule`, `hostname`, `tags` (comma-joined) and `timestamp`.
  **It does not send `output_fields`, `uuid` or custom fields.** The scope name is `falco`; the
  resource is fixed to `service.name = "falco"` and the service version, and does not read
  `OTEL_RESOURCE_ATTRIBUTES`. The logs exporter's TLS check reads the traces `checkcert` setting.
- Export uses the SDK batch processor: a failed export is retried by the OTLP exporter and then
  dropped, counted in Falcosidekick's own output metrics.

Without `output_fields` there is no pod, namespace, container, or process context, so the
normalization this change exists for is impossible. The output must be extended (Decision 9).

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
  `latest_occurrence_id`, `last_resolved_at`, `suppressed_until`, `suppressed_by`,
  `suppression_reason`, `transition_seq`.
- Runtime attributes stay off the cross-class table; typed columns give indexed SRQL filters.

### Decision 2: The subject entity is the most specific stable one

| `entity_kind` | When | `entity_key` coordinates |
| --- | --- | --- |
| `k8s_workload` | namespace, owner kind and owner name are known | `cluster_id / namespace / owner_kind / owner_name` |
| `k8s_pod` | namespace and pod are known, owner is not | `cluster_id / namespace / pod_name` |
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
- **Partition** is the attested `Sr-Partition` of the relay record. **Cluster id** is the
  resource attribute `serviceradar.cluster_id` (Decision 9), defaulting to `default`. It is
  sender-asserted and used only as a key within the attested partition.
- **Finding uid** = `deterministic_uuid("falco:runtime-finding:v1:" <> entity_kind <> "|" <>
  entity_key <> "|" <> rule)`. It never includes container id, pod uid, device uid or the ingest
  subject, so a binding can arrive, change or follow a DIRE merge without changing the finding.
- **Rule identity** is the Falco rule name. A renamed rule is a new finding.

### Decision 3: Inventory binding records how it was made, and never guesses

`DeviceCorrelation` is extended to return `{device_uid | nil, method, candidates}`. The same
resolution runs for the subject (`device_uid`) and for the node the occurrence ran on
(`node_device_uid`).

- **Methods, strongest first:** `explicit_uid`; `agent` (an agent id that exists, including the
  relaying agent when the record's hostname is that agent's own host); `workload_identity`;
  `k8s_node` (node name to `k8s_nodes_current.internal_ip`, then to a device by IP in the
  partition); `hostname_unique`.
- **The relaying agent is provenance, not location.** In a cluster one in-cluster agent relays for
  every node, so `Sr-Agent-Id` binds a record to its host only in the colocated case above.
- **Ambiguity is a state.** A hostname matching more than one non-deleted device yields
  `binding_status = ambiguous` with `binding_candidates = n` and no device.
- **Unbound is a state.** No candidate yields `unbound`; the finding is created, listed under
  unbound findings, and shown on no device page.
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
- **Occurrence id** is derived from the Falco `uuid` (now carried, Decision 9), otherwise from the
  digest of the raw record.
- **Write order:** spilled raw objects (Decision 6), then the occurrence load, then the finding
  upsert and transition outbox. A failure at any step fails the batch and JetStream redelivers it.
- **No generic `logs` row** (user decision). A recognized Falco record is not written to `logs`;
  the occurrence holds the raw record and is queryable through SRQL.
- **Free-text column widths.** In the warehouse, `process_cmdline`, `fd_name` and the other
  free-text columns are `VARCHAR(1048576)`, so no typed column is ever cut. The full record is
  always in the raw evidence.

### Decision 6: Raw evidence is lossless; large records go out-of-line, never cut

- **What raw evidence is.** The `falco.event` attribute (Decision 9) carries the Falco event JSON
  as Falcosidekick received it. `raw_payload` stores those bytes unchanged; `raw_sha256` and
  `raw_bytes` describe them. If a record lacks `falco.event`, the raw evidence is the canonical
  OTLP/JSON encoding of that log record with its resource and scope.
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
- **Reality check.** A single edge record is at most 512 KiB, so a relayed Falco record cannot
  exceed the inline threshold today. The spill path exists so the never-truncate rule holds without
  depending on that bound.

### Decision 7: Lifecycle and alerting

- `active` -> `resolved` automatically after a quiet period with no new occurrence (default 24 h,
  configurable as `runtime_findings.auto_resolve_after`), or by an operator.
- `resolved` -> `active` on a new occurrence (`reopen_count += 1`, a new episode starts).
- `active` -> `suppressed` by an operator, with optional expiry and reason. Suppressed findings
  keep counting and sampling but emit no alerting transitions.
- **Alerting is lifecycle only** (user decision): `opened`, `reopened`, `escalated` (episode
  severity rose), `resolved`. There is no volume or rate alert.
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

### Decision 9: Transport is the durable edge-record pipeline from day one

Falco reaches ServiceRadar only as OTLP logs relayed on edge records. The NATS `falco.*` path is
removed in the same rollout.

**Path:** Falco `http_output` -> Falcosidekick -> OTLP logs (gRPC) -> the `otel-collector` add-on
on the agent -> `OtlpRelayFrame` in the agent edge spool -> gateway -> OTLP relay projector ->
`logs.otel` with attested headers -> EventWriter `Logs` processor -> Falco recognizer -> Falco
normalizer.

**Falcosidekick output extension (dependency).** The OTLP logs output must carry the whole event.
The patch is upstreamed to falcosecurity/falcosidekick and, until released, shipped from the
maintained fork at a pinned version. Each log record gets:

- attributes `falco.uuid`, `falco.rule`, `falco.priority`, `falco.source`, `falco.hostname`,
  `falco.time` (RFC 3339 nanoseconds), `falco.tags` (string array), every output field as
  `falco.output_fields.<field>` with its native type, every custom or templated field as
  `falco.custom_fields.<key>`, and `falco.event` (the Falco event JSON);
- severity mapped from the Falco priority, not a fixed Info;
- a resource that merges `OTEL_RESOURCE_ATTRIBUTES` (SDK environment detector) over the defaults;
- a logs-specific `checkcert`, instead of the traces setting.

**Falcosidekick configuration** (environment form; the chart renders it, below):

```
OTLP_LOGS_ENDPOINT=https://serviceradar-agent.<namespace>.svc:14317
OTLP_LOGS_PROTOCOL=grpc
OTLP_LOGS_HEADERS=x-serviceradar-ingestion-key=<token>
OTLP_LOGS_MINIMUMPRIORITY=              # empty: every priority
OTLP_LOGS_CHECKCERT=true
OTEL_EXPORTER_OTLP_LOGS_CERTIFICATE=/etc/serviceradar/falco-otlp/ca.pem
OTEL_RESOURCE_ATTRIBUTES=serviceradar.source=falco,serviceradar.cluster_id=<cluster id>
```

No NATS output and no NATS credentials are configured.

**Chart wiring (ServiceRadar chart):**

- `falcoIngest.enabled` (default `false`), `falcoIngest.clusterId` (default `default`),
  `falcoIngest.namespace` (where the Falcosidekick release runs; default the release namespace),
  `agent.otlpReceiver.port` (default `14317`; the agent runs with `hostNetwork`, so the port avoids
  node-level collectors on 4317).
- When enabled: the `serviceradar-agent` Service exposes `otlp-grpc` on that port; core creates a
  managed `otel-collector` add-on assignment for the in-cluster agent binding the port with the
  platform `grpc_tls` certificate and `auth.enabled = true`, and seeds the edge contract
  registry entry `{"serviceradar.otlp.relay", 1}` and the agent's grant; the chart renders the
  Secret `serviceradar-falcosidekick-otlp` in `falcoIngest.namespace` holding the environment
  above, the ingestion token and the CA bundle, for the Falco release to consume with `envFrom`
  and a volume; the network policy admits `falcoIngest.namespace` to the receiver port.
- The ingestion token is ServiceRadar ingest credential material of the same kind as the existing
  `otlp.auth` Secret, not a device or integration credential.
- The Falcosidekick collector package type stops provisioning NATS credentials and renders the same
  OTLP configuration pointing at the site's agent receiver.

**Recognition.** The `Logs` processor treats a log record as Falco only when all hold:

1. it arrived through the OTLP relay: the message has `Sr-Ingest-Identity` starting `agent:`, and
   `Sr-Agent-Id` and `Sr-Partition` are present;
2. resource `service.name = "falco"` and `serviceradar.source = "falco"`;
3. scope name `falco`;
4. attributes `falco.rule` and `falco.priority` are present.

A record meeting 1-3 but not 4 is a malformed Falco record: it is stored as an ordinary log and
counted (`falco_record_malformed`), never discarded. A Falco-shaped record that did not arrive
through the relay (1 fails) is an ordinary log and is counted (`falco_record_unrelayed`); it never
creates findings, which keeps one path. Within one message, records are routed one by one; the
message is acknowledged only after both its ordinary log rows and its Falco occurrences and
finding updates are stored.

**Removal in the same rollout (per-producer cutoff).** The release that ships the edge path
removes: the `FALCO` consumer and `Processors.FalcoEvents` (`config.ex`, both `runtime.exs`
files), the pipeline's `falco` routing, `falco.>` from the chart NATS permissions and leaf
credentials, `events.falco.>` from `NatsLeafConfigGenerator`, the `serviceradar-falcosidekick`
NATS user and its certificate generation, and NATS credentials on Falcosidekick collector
packages (existing ones are revoked). Release notes require reconfiguring every Falcosidekick to
OTLP in that upgrade; an unmigrated sender is refused by NATS, and its own output metrics show
the failures. There is no flag that keeps both paths.

**Delivery confirmation (task 0.4).** From the moment the add-on returns OTLP success, a record
is in the add-on spool, then the agent edge spool, and only leaves each after an acknowledgement
up to a JetStream PubAck. That answers the confirmation question for every hop from the receiver
on. Two loss points remain and are documented, not designed around: Falcosidekick's OTLP batch
exporter drops after its retries when the receiver is unreachable (counted in its metrics), and the
add-on spool evicts its oldest segment when it reaches `agent_forward.max_bytes` during a long
upstream outage (counted).

**Dependency.** Sibling task 4.1 of `move-agent-telemetry-to-edge-records` (the `OtlpRelayFrame`
producer and projector) must ship in the same or an earlier release. A single OTLP log record
larger than the 512 KiB record bound must be refused back to the sender by that contract, never
dropped; this change depends on that behavior.

### Decision 10: SRQL entities

- `in:runtime_findings` (aliases `runtime_finding`, `falco_findings`) reads
  `ocsf_findings JOIN runtime_finding_details` in CNPG on both backends. Filters: `status`,
  `severity`, `rule`, `priority`, `entity_kind`, `cluster`, `namespace`, `owner_kind`, `owner`,
  `pod`, `hostname`, `device_uid`, `node_device_uid`, `binding_status`, `attribution`, `tactic`,
  `technique`, `first_seen`, `last_seen`, `time:` (on `last_seen`), `finding_uid`. Default sort
  `last_seen:desc`; stats counts by rule, namespace, owner, device.
- `in:runtime_security_occurrences` (alias `runtime_occurrences`) reads the active telemetry
  backend with the typed columns of Decision 5. `raw_payload` and `raw_ref` are returned only when
  selected or on single-row detail.
- When `add-ocsf-finding-model` moves `in:security_findings` onto `ocsf_findings`, Falco findings
  appear there through the common columns.
- The occurrence reader has CNPG and warehouse implementations; the result-diff parity harness of
  `extend-starrocks-to-all-telemetry` Decision 2 gates the warehouse reader.

### Decision 11: Retention

| Data | Store | Retention |
| --- | --- | --- |
| Active and suppressed findings | CNPG | kept while active or suppressed |
| Resolved findings | CNPG | deleted `runtime_findings.resolved_retention` after `last_resolved_at` (default 90 days), bounded prune job |
| Occurrences | StarRocks or CNPG | dataset telemetry retention on the active backend |
| Spilled raw objects | datasvc object store | same day as their occurrence partition, plus one day (Decision 6) |
| Transition events | `ocsf_events` | event retention, unchanged |
| Outbox rows | CNPG | deleted on relay; age monitored |

Deleting a finding does not delete its occurrences.

### Decision 12: UI

- **Device page, Runtime security tab:** findings whose `device_uid` or `node_device_uid` is this
  device, active first, then by severity and `last_seen`; loaded after the socket connects, paged
  through SRQL, rendered with streams.
- **`/security` Runtime findings view:** filters by cluster, namespace, owner, rule, status and
  binding; grouped by workload; an Unbound filter for ambiguous and unbound findings.
- **Finding detail `/security/runtime-findings/:uid`:** subject and binding, attribution, samples,
  occurrence timeline, latest occurrences, raw evidence viewer (inline or streamed from the object
  store with digest check), lifecycle history, RBAC-gated resolve and suppress.
- **Alert detail** links to the finding; the `security-findings` dashboard package moves its Falco
  frames to `in:runtime_findings`; Logs and Events point their Falco source filter at the view.

## Migration Plan

1. CNPG migrations: `ocsf_findings`, `finding_info_uid` on `ocsf_events`,
   `runtime_finding_details`, the transition outbox, the `runtime_security_occurrences` hypertable.
   StarRocks migrations: `runtime_security_occurrences`, `finding_info_uid` on `events`.
2. One release ships the edge path and removes the NATS path (Decision 9), together with sibling
   task 4.1 and the pinned Falcosidekick build.
3. The seeder creates `falco_runtime_finding` and retires `falco_critical_incident`.
4. **Forward-only, no backfill** (user decision). Findings start at the first relayed occurrence.
   Historical Falco rows in `ocsf_events` and `logs` stay readable until retention removes them.
5. Operators reconfigure Falcosidekick to OTLP during the upgrade (chart Secret, or a regenerated
   collector package).
6. Rollback is a release rollback. The NATS path is gone in the new release, so rolling back also
   needs the old Falcosidekick configuration; release notes say so.

## Risks / Trade-offs

- **Upstream dependency.** The edge path is useless without the Falcosidekick output extension.
  Mitigation: a pinned build from the maintained fork until upstream releases it.
- **Sender-hop loss** before OTLP acceptance, and add-on spool eviction under a long outage.
  Both are counted and documented.
- **Sender-asserted attributes.** `serviceradar.cluster_id` and the Falco fields come from the
  sender; identity and partition come from the attested edge record. A publisher allowed on
  `logs.otel` could set the relay headers itself; NATS permissions limit who that is.
- **Pod-level findings split on rollout** when no owner is known; accepted over a guessing
  heuristic.
- **At-least-once counts** in the commit-to-ACK window.
- **Operators lose Falco rows in Events and Logs**; release notes and replacement links cover it.
- **New telemetry dataset cost** in both backends, accepted for typed filters and lossless
  evidence.

## Open Questions

None. The user decided the logs row, count semantics, alerting scope, quiet period, oversize
handling, migration, sequencing and transport on 2026-11-02 and 2026-11-03.
