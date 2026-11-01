# Design: Move agent telemetry onto the durable edge-record pipeline

## Context

The shared transport exists and is proven on leased sweeps: agent spool with
prepaid terminal evidence, `EdgeRecordIngestService.Stream`, gateway four-part
authorization, JetStream `TELEMETRY_EDGE_RECORD_V1_BULK` with PubAck before the
agent reclaims, and the EventWriter `EdgeRecord` ledger. This change adds the
producers. It does not change the wire ABI frozen by `freeze-edge-record-v1-abi`.

Today's producers, their payloads, and their sinks (from a full inventory of
`go/pkg/agent` send sites on staging a963915b):

| Family | Payload today | Lossy today | Sink today |
| --- | --- | --- | --- |
| Sysmon, SNMP, ICMP, MTR/sweep metrics, rperf | `MetricBatch` | yes | `metrics.>` -> `Processors.Metrics` |
| MTR traces | JSON results | yes | core -> `mtr.results.ingest` -> `Processors.Mtr` |
| Plugin signals, add-on telemetry | `TelemetryBatch` | yes | metrics, OCSF, OTel logs, discovery |
| OTLP relay | `addon.v1.OtlpRelayFrame` window | no (add-on spool) | OTel traces/metrics/logs processors |
| Flow attribution | `netprobe.v1.FlowAttributionEventBatch` | in-memory retry | StarRocks flow attribution |
| Wasm plugin results | JSON + `PluginResultProvenance` | in-memory retry | `PluginResultIngestor` |
| Mapper, netprobe discovery, sync pages | JSON | yes | ResultIngestor -> SyncIngestor queues |
| Workload identity, SBOM, bumblebee, k8s endpoints | JSON / spool bytes | disk spool | inventory ingestors |

## Decisions

### Decision 1: One output contract per data family, carrying the existing protobuf

A contract is identified by `contract_id` and version in the signed registry the
gateway already loads. Where a typed protobuf exists it becomes the record
payload unchanged, so producers and projectors reuse their encoders and decoders.
`metric.v1.MetricBatch` is the payload of two contracts, because one payload rule
cannot both forbid source authorization and require it. They share one projector
and the existing metrics destination.
`serviceradar.metrics.batch` v1 is the passive contract: a standing grant, and
records carry no source authorization. Sysmon uses it, and so does any other
passive metric producer.
`serviceradar.metrics.scheduled` v1 is the lease-run contract. Records carry a
source authorization: `SCHEDULED_CHECK` for SNMP, ICMP, and MTR metrics and for
rperf, and `SCHEDULED_SWEEP` for a sweep metric batch under the sweep lease.
A sweep group that has hosts and an ICMP or TCP check, and no lease yet, emits
that batch only together with its sweep results, once its sweep lease exists.
A nothing-to-scan group emits no sweep metric batch. Banner results are not
part of either metrics contract.

JSON producers do not get a "JSON blob" contract. Each gets a typed batch message
first, because the pipeline's semantic digest, idempotency key and projector
validation need a typed body. Wrapping legacy JSON would move the bytes without
the guarantees.

Alternative rejected: a single generic "status chunk" contract carrying
`GatewayStatusChunk`. It would move everything fastest, but it re-creates the
untyped envelope the pipeline exists to remove, leaves JSON payloads, and lets one
contract smuggle arbitrary future data past registry review.

### Decision 2: Two grant models, both inside the frozen ABI

- **Check leases** mirror sweep leases for the producers this change schedules
  with them: MTR checks, ICMP checks, SNMP polls, plugin runs, mapper jobs, and
  sync runs. Core mints execution slots per (assignment, schedule), signs a
  production capability per lease and a `SCHEDULED_CHECK` source authorization
  per execution (`INTEGRATION_RUN` for sync runs), and delivers them on the
  control stream the sweep lease carrier already uses. Missed-run marking, epoch
  fencing and lease-pass scheduling reuse the M2.0 machinery. Generalizing that
  scheduler does not retarget sweep slots.
- Sweep executions, including banner results and the sweep metric batches on
  `serviceradar.metrics.scheduled` v1, keep
  `EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP` under the existing sweep
  lease. SNMP, ICMP, and MTR metrics and rperf on that same contract carry
  `SCHEDULED_CHECK`. Generalizing the scheduler leaves sweep slots on
  `SCHEDULED_SWEEP`. Traces from a sweep whose modes include mtr are the MTR
  check-lease family (`MtrTraceBatchV1`, `SCHEDULED_CHECK`). They move when MTR
  checks move, with no dependency on that group's sweep lease.
- **Standing output grants** cover passive producers, including
  `serviceradar.metrics.batch` v1. Core signs one production capability per
  (agent, contract, authority epoch) with a bounded validity window and renews
  it while the agent is enrolled and the contract is enabled. Records carry no
  source authorization; the record layer already allows that, and each passive
  contract's payload rules state it explicitly. Revocation bumps the
  epoch; the gateway refuses stale epochs without a delivery grant exactly as it
  does for sweeps.

### Decision 3: One agent-side producer sink

Every migrated producer appends through one sink that validates the producer's
grant, assigns event identity, encodes the record, and returns only after the
spool commit is durable. This is the in-process subset of USP-01 task 2.10. It
replaces each drain-before-send buffer with "append, then forget": the spool owns
the record from then on. Admission refusal is returned to the producer as
retryable backpressure; a producer that cannot wait drops with a counted reason,
never silently.

### Decision 4: Projectors write today's destinations inside the ledger transaction

Each contract gets an EventWriter projector that decodes the payload and calls the
same domain logic the legacy path calls, inside the `EdgeRecord` ledger
transaction, so a redelivered record is a no-op. The two metrics contracts share
that one metrics projector and destination. Telemetry destinations follow the
repository rule: StarRocks when enabled, CNPG otherwise, never both. Flow and
exposure data stay StarRocks-only.

### Decision 5: One coordinated cutover after per-family parity soaks

Each family is soaked behind a per-agent opt-in. A producer emits on exactly one
path at a time. Parity soaks (row counts, values, timestamps against a control
agent) run per family before cutover. The next release removes legacy agent
status-path emission and the gateway's matching publishers together, after every
sweep group that has hosts and an ICMP or TCP check has a signed sweep lease.
A nothing-to-scan group counts as satisfied. There is no long-lived per-family
legacy. Order of the soaks, by loss exposure and payload
readiness:

1. Passive metrics, `serviceradar.metrics.batch` v1 (sysmon and any other passive
   metric producer): standing grant, no source authorization.
2. Lease-run metrics, `serviceradar.metrics.scheduled` v1 (SNMP, ICMP, and MTR
   metrics and rperf under `SCHEDULED_CHECK`; sweep metric batches under
   `SCHEDULED_SWEEP`). Same `MetricBatch` payload, projector, and destination as
   item 1. A group that still has hosts and an ICMP or TCP check, and no lease
   yet, keeps its sweep metric batch with its sweep results until that lease
   exists (Decision 6 and Decision 7). A nothing-to-scan group emits neither.
3. MTR traces (`MtrTraceBatchV1`, already frozen) under check leases (USP-01 M4.3).
4. Flow attribution and OTLP relay: typed, already ack-shaped.
5. Plugin signals and native add-on telemetry (`TelemetryBatch`), then Wasm plugin
   results via a typed result batch (USP-01 tasks 2.11, 2.12, 2.14).
6. Inventory producers (mapper, netprobe discovery, sync pages, workload identity,
   endpoint inventory, bumblebee, k8s endpoints) after their typed batch contracts.
7. Query-resolved sweeps, still before the cutover release: sign
   `SweepCompiler` target resolution under the existing sweep lease
   (Decision 6).
8. Lease homes for the groups the sweep lease skips today (Decision 7), before
   the same cutover.

### Decision 6: Query-resolved sweeps freeze the compiler scan set

Sweep groups with a `target_query` are in scope as the final phase before the
cutover release. The signed plan is the targets returned by `SweepCompiler`'s
target resolution, the same function the compiler uses today, not a second
resolver. That function scopes the query with `normalize_target_query`.
`SRQLQuery.ensure_target/2` prepends `in:devices` only when the trimmed query
does not already start with `in:`; an existing `in:` target is left unchanged.
It appends `partition:<group partition>` unless the query already names
partition. It keeps aliases that are strict IPs of `alias_type` ip in state
confirmed, updated, or detected, inside the AliasRecency window, not already a
primary, and capped at `sweep_max_alias_targets_per_device`, drops a non-address
value for that row (a CIDR in the ip column is not planned as a prefix), and
includes the group's static targets. The plan uses the existing sweep lease and
`EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP`. A successful read whose targets
differ, and that still has hosts and an ICMP or TCP check, re-plans. A set that
exceeds plan limits is split across executions or ranges so every returned
member is in a signed plan. The group's sweep results and sweep metric batch
move together once that lease exists.

A failed device read, including a later page error or an alias-table error,
keeps the last signed plan. Core does not sign the pages already fetched, a plan
that omits aliases, or an empty plan. When a failed read has no signed plan yet,
the group waits for a successful read. An unparseable query, and a query that
parses but cannot be translated or cast, contributes no hosts and does not keep
the last plan. The group's static targets still run when an ICMP or TCP check
remains. When that leaves no hosts, the withdrawal below applies.

When a successful resolution plus static targets yields no hosts, a query that
cannot be parsed, translated, or cast plus static targets yields no hosts, or
the modes leave no ICMP or TCP sweep check (mtr only, tcp or tcp_connect with no
ports, or only modes SweepCompiler drops), core does not sign an empty plan. It
withdraws the group's sweep lease with a revoked SweepLeaseV1 push, so the agent
drops unrun slots and stops scanning previously selected targets. Core records
an operator-visible nothing-to-scan state and signs a lease again when a later
resolution or edit yields hosts and an ICMP or TCP check. Closure counts that
group as satisfied because it emits no durable sweep data. An mtr-only group's
traces run as `MtrTraceBatchV1` under MTR check leases and that group has no
sweep lease. A failed read still keeps the last signed plan.

A static target the plan builder cannot represent, including an IPv6 prefix wider
than /65 (refused today as `:target_too_wide`), is refused when the sweep group
is configured. A CIDR in a query ip column is dropped for that row and does not
refuse the group. The error is visible to the operator. An existing group with
such a static target is reported as not runnable. It does not run on the legacy
path, and it does not emit edge records.

### Decision 7: Groups the sweep lease skips today get a home before cutover

Closure still requires every sweep group that has hosts and an ICMP or TCP check
to hold a signed sweep lease. A nothing-to-scan group counts as satisfied
(Decision 6). Three eligibility gaps are closed before cutover, without changing
`EdgeRecordV1` or any frozen payload.

- **Short intervals.** `LeaseSchedule.min_interval_seconds` drops from 300 to 1,
  so every whole-second interval leases, and so does a cron whose closest fires
  are at least one second apart. The cost is slots per horizon: a one-second
  group over seven days is about 604800 executions, 300 times the about 2000
  executions of the five-minute floor, and each execution still signs once per
  target. A schedule denser than one second is refused at configuration.
- **MTR mode.** A sweep group whose modes include mtr is not refused. When an
  ICMP or TCP check remains, reachability and port results stay on that sweep
  lease under `SCHEDULED_SWEEP`. Traces are `MtrTraceBatchV1` under the MTR check
  lease (`SCHEDULED_CHECK`) when MTR checks move, with no dependency on that
  group's sweep lease. An mtr-only group has no sweep lease; its traces run
  entirely under those MTR check leases (Decision 6). SweepPlan no longer
  refuses the group for mtr mode. TCP modes with no ports, and modes outside
  icmp, tcp, tcp_connect, and mtr, are dropped. Remaining ICMP or TCP checks
  still run. When none remain, the group is nothing to scan, not a refusal.
- **Banner grab.** Banner results are a new typed batch on their own registry
  contract. The contract is additive. Banner results for an execution carry that
  execution's sweep lease and `SCHEDULED_SWEEP`.

Anything still unrepresentable after those three, which is a static target the
plan builder cannot represent or a schedule denser than one second, is refused
at sweep group configuration with an operator-visible error. An existing group
is reported as not runnable and does not run on the legacy path. Nothing to scan
is not that refusal.

## Risks

- **Grant volume.** Standing grants are per (agent, contract), not per record;
  check leases reuse the sweep lease horizon. Both are bounded by assignments.
  Lowering the sweep interval floor to one second multiplies slots per horizon
  by up to 300 versus the five-minute floor (Decision 7).
- **Spool sharing.** All producers share one spool budget. Fair interleaving across
  lanes (USP-01 task 2.7) and admission backpressure (M3.2) become required before
  high-volume families move, so metrics cannot starve sweeps or MTR.
- **Mixed fleets.** Agents that are not opted in keep the legacy path until the
  cutover release. That release removes the legacy emission and the gateway
  publishers together.
