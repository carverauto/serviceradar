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
`metric.v1.MetricBatch` covers sysmon, SNMP, ICMP, MTR metrics, sweep metrics and
rperf as ONE contract, `serviceradar.metrics.batch`, because they share one sink
and one schema; `ProducerKind` inside the batch already distinguishes them. Sweep
metric batches on that contract are a byproduct of the sweep lease. They keep
`EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP`. They are not a standing grant
and they are not `SCHEDULED_CHECK`.

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
- Sweep executions, including the metric batches a sweep lease produces, keep
  `EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP` under the existing sweep
  lease. Generalizing the scheduler leaves those sweep slots on that kind.
- **Standing output grants** cover passive producers. Core signs one production
  capability per (agent, contract, authority epoch) with a bounded validity window
  and renews it while the agent is enrolled and the contract is enabled. Records
  carry no source authorization; the record layer already allows that, and each
  passive contract's payload rules state it explicitly. Revocation bumps the
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
transaction, so a redelivered record is a no-op. Telemetry destinations follow the
repository rule: StarRocks when enabled, CNPG otherwise, never both. Flow and
exposure data stay StarRocks-only.

### Decision 5: Migrate one family at a time, one path per producer

Each family moves behind a per-agent opt-in. A producer emits on exactly one path
at a time; an opted-in agent stops the legacy emission for that producer in the
same release. After a farm01 parity soak (row counts, values, timestamps against a
control agent), a separately gated release removes the legacy emission and the
gateway's matching publisher. Order, by loss exposure and payload readiness:

1. `serviceradar.metrics.batch` (sysmon, SNMP, ICMP, MTR metrics, sweep metrics,
   rperf): highest volume, typed, lossy today. Passive producers and check-leased
   producers share this contract. Sweep metric batches keep `SCHEDULED_SWEEP`
   under the sweep lease that produced them.
2. MTR traces (`MtrTraceBatchV1`, already frozen) under check leases (USP-01 M4.3).
3. Flow attribution and OTLP relay: typed, already ack-shaped.
4. Plugin signals and native add-on telemetry (`TelemetryBatch`), then Wasm plugin
   results via a typed result batch (USP-01 tasks 2.11, 2.12, 2.14).
5. Inventory producers (mapper, netprobe discovery, sync pages, workload identity,
   endpoint inventory, bumblebee, k8s endpoints) after their typed batch contracts.
6. Query-resolved sweeps, last: resolve `target_query` at lease time into a
   signed scheduled plan under the existing sweep lease (Decision 6).

### Decision 6: Query-resolved sweeps freeze a signed plan per execution

Sweep groups with a `target_query` are in scope as the final phase. Core resolves
the `target_query` at lease time and freezes the resolved address set into a
signed scheduled plan for that execution. The plan uses the existing sweep lease
machinery and `EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP`. When the resolved
set changes, core re-plans. The frozen set must fit the plan builder's range
limits. A group whose resolved set cannot be represented stays on the legacy
path and is reported. It is not silently dropped.

## Risks

- **Grant volume.** Standing grants are per (agent, contract), not per record;
  check leases reuse the sweep lease horizon. Both are bounded by assignments.
- **Spool sharing.** All producers share one spool budget. Fair interleaving across
  lanes (USP-01 task 2.7) and admission backpressure (M3.2) become required before
  high-volume families move, so metrics cannot starve sweeps or MTR.
- **Mixed fleets.** Agents that are not opted in keep the legacy path unchanged; the
  gateway keeps both receivers until every agent of a family has moved.
