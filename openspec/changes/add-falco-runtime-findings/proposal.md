# Change: Normalize Falco events into per-entity runtime security findings

## Why

Falco detections are not actionable today. Every Falco event becomes three records -- a `logs`
row, an `ocsf_events` row whose `message` is Falco's whole `output` string and whose
`unmapped` is the whole payload, and an admission into `StatefulAlertEngine` through the
managed rule `falco_critical_incident` (`signal: :event`, `subject_prefix: "falco."`,
`severity_number_min: 5`, `group_by: ["rule", "hostname"]`). The alert an operator receives is
therefore a report-sized blob about a hostname string, not a statement about a device or a
workload in the inventory.

Three structural problems sit underneath that:

1. **There is no finding.** The OCSF `finding_info.uid` that `FalcoDecomposition.finding_info/3`
   computes includes `container_id` and the ingest subject, so it changes every time a pod
   restarts. Nothing stores "rule R is firing on workload W since T, N times"; the only durable
   aggregate is a stateful-alert group keyed on a hostname string.
2. **The alert engine is the aggregator.** Every Falco occurrence is an alert input, so a burst
   from one DaemonSet is thousands of admissions for what is one problem. Bursts exceed the
   per-rule admission budget (a generic no-loss fix is in progress separately and is not part of
   this change), and even when admitted, the engine is doing deduplication work that belongs in
   the data model.
3. **Evidence is tied to strings, not inventory.** `DeviceCorrelation.resolve/1` is called, but
   its result is a best-effort `device_uid` on the event. A hostname that matches two devices
   silently picks one by sort order, and an unresolved host leaves nothing to re-resolve later.
   On a StarRocks installation the warehouse `events` row also truncates `message` at 65,533
   bytes and carries no `raw_data` column at all, so the raw Falco record is not retained there.

## What Changes

- **Normalized runtime findings (CNPG, current state).** Falco occurrences are folded into one
  finding per `(subject entity, Falco rule)` in the canonical `platform.ocsf_findings` store
  (OCSF Detection Finding, class 2004) planned by `add-ocsf-finding-model`, with a typed 1:1
  extension table for runtime attributes. Each finding carries status, severity, first/last
  seen, lifetime and per-episode occurrence counts, a fixed-window rate counter, bounded
  top-N samples (process, command, image, node, user), and its inventory binding.
- **Explicit entity model.** The subject is the most specific stable entity the event supports:
  Kubernetes workload (cluster, namespace, owner kind, owner name), else Kubernetes pod, else
  host, else non-syscall Falco source. The finding identity is derived from observed coordinates,
  never from `container_id`, so a pod restart or rollout does not create a new finding.
- **Inventory binding with explicit failure states.** Each finding records a device binding
  (`bound` with the resolution method, `ambiguous` with a candidate count, or `unbound`) for the
  subject and for the node it ran on. Ambiguous hostname matches are never resolved by guessing.
  A bounded re-resolution job binds findings once inventory catches up. Falco never creates,
  merges, or revives devices.
- **Typed occurrence history (telemetry).** A new append-only dataset,
  `runtime_security_occurrences`, stores every Falco event with typed columns for the key
  `output_fields` and the raw payload retained byte-exact. It follows the hard rule: StarRocks
  only when enabled, CNPG otherwise, never both. Falco occurrences stop being written to
  `ocsf_events` and the direct processor stops writing a duplicate `logs` row.
- **Alert on findings, not occurrences.** Finding lifecycle transitions (`opened`, `reopened`,
  `escalated`, `resolved`) are emitted as low-volume OCSF Detection Finding events in
  `ocsf_events` through a transactional outbox. A new managed stateful rule,
  `falco_runtime_finding`, groups by `finding_info.uid` with cooldown and renotify, and recovers
  on `resolved`. Alert volume becomes proportional to distinct findings, not to event rate.
- **Retire `falco_critical_incident`.** The seeder gains a retire list. A pristine managed copy
  is disabled and marked retired, and its active alerts are resolved as superseded. An
  operator-modified or unmanaged copy is left in place, flagged in Settings, and logged.
- **SRQL.** New entities `in:runtime_findings` (CNPG, both backends) and
  `in:runtime_security_occurrences` (warehouse or CNPG by backend), with typed fields.
- **UI.** A Runtime security tab on the device page (findings whose subject or node is bound to
  the device), a Runtime findings view on `/security` with workload grouping, and a finding
  detail page with samples, occurrence timeline and raw evidence.
- **Transport stays on NATS JetStream.** Falcosidekick keeps publishing `falco.>`; the
  normalizer is transport-independent so a future agent-hosted receiver on the edge-record
  pipeline can feed it unchanged. The design records why the edge-record pipeline is not
  adopted now.
- **Collector package.** The Falcosidekick collector bundle stamps `serviceradar.cluster_id`
  and `serviceradar.partition` custom fields so findings can be keyed per cluster.

## Impact

- Affected specs: `runtime-security-findings` (new), `observability-signals`, `srql`,
  `build-web-ui`.
- Affected code: `ServiceRadar.EventWriter.FalcoDecomposition`,
  `ServiceRadar.EventWriter.Processors.FalcoEvents`, the Falco branch of
  `ServiceRadar.Observability.LogPromotion`, `ServiceRadar.EventWriter.DeviceCorrelation`,
  `ServiceRadar.Observability.RuleSeeder`, `ServiceRadar.Analytics.StarRocks.Rows` and readers,
  CNPG and StarRocks migrations, `rust/srql`, web-ng device and security LiveViews, the
  `security-findings` dashboard package, the Falcosidekick collector bundle generator, and docs.
- Related changes: builds on `add-ocsf-finding-model` (this change can be the first producer of
  `platform.ocsf_findings` and delivers its Falco tasks 2.3, 2.4, 3.1); keeps the diagnostics
  contract of `update-falco-alert-diagnostics`; does not touch the admission work in
  `refactor-durable-alert-admission`; consumes `platform.workload_identity_current` from
  `add-workload-identity-enrichment`.
- **BREAKING (operator-visible):** Falco occurrences no longer appear in `in:events` /
  `in:security_findings` or the Logs page; their history moves to
  `in:runtime_security_occurrences`. The `falco_critical_incident` rule is retired. Existing
  Falco rows in `ocsf_events` and `logs` stay readable until retention ages them out.
- Data: forward-only. No backfill of historical Falco events into findings.
