# Design: Move agent telemetry onto the durable edge-record pipeline

## Context

The shared transport exists and is proven on leased sweeps: agent spool with prepaid terminal
evidence and bounded quarantine, `EdgeRecordIngestService.Stream`, gateway four-part
authorization, JetStream `TELEMETRY_EDGE_RECORD_V1_BULK` with PubAck before the agent reclaims,
and the EventWriter `EdgeRecord` ledger. This change adds the producers. It does not change the
wire ABI frozen by `freeze-edge-record-v1-abi`.

| Family | Payload today | Sink today |
| --- | --- | --- |
| Sysmon, SNMP, ICMP, rperf, MTR metrics | `MetricBatch` | `metrics.>` -> `Processors.Metrics` |
| Periodic sweep summary | `MetricBatch` | status interval -> `metrics.>` |
| Unleased sweep-results chunk metrics | `MetricBatch` | sweep-results push -> `metrics.>` |
| MTR traces | JSON results | core -> `mtr.results.ingest` -> `Processors.Mtr` |
| Unleased sweep results | JSON results | `SweepResultsIngestor` |
| Plugin signals, add-on telemetry | `TelemetryBatch` | metrics, OCSF, OTel logs, discovery |
| OTLP relay | `addon.v1.OtlpRelayFrame` window | OTel processors |
| Flow attribution | `netprobe.v1.FlowAttributionEventBatch` | StarRocks flow attribution |
| Wasm plugin results | JSON + `PluginResultProvenance` | `PluginResultIngestor` |
| Mapper, netprobe discovery, sync pages | JSON | ResultIngestor -> SyncIngestor |
| Workload identity, SBOM, bumblebee, k8s endpoints | JSON / spool bytes | inventory ingestors |

## Decisions

### Decision 1: Authority follows who schedules each run

A **sweep lease** exists where core decides each run ahead of time and can sign what the run may
do: a leased static sweep's plan binds its target ranges and checks, and each execution carries a
`SCHEDULED_SWEEP` source authorization. That model is unchanged, including the single production
capability on `SweepLeaseV1`. A leased execution emits no metric batch of its own.

Everything else runs on the agent's own schedule from the config core delivered. Signing each of
those runs would mean a core-planned slot and a database row per poll for work the config already
authorizes, so they emit under a **standing output grant** instead: one production capability per
(agent, contract, authority epoch), fenced like a sweep producer assignment. Records under a
standing grant carry no source authorization, and each such contract's payload rules state that.
A lease-signed record is outside that rule. Leased static sweep results stay
`SweepObservationBatchV1` on `serviceradar.sweep.observation`, authorized by the lease capability
and `SCHEDULED_SWEEP`.

Trade-off: a standing-grant record is not checked against a signed per-run plan, so core cannot
prove an unleased sweep scanned exactly what its config asked. That is the trust level the legacy
path has today, and the per-agent principal, network scope and epoch fence still apply.

### Decision 2: Standing grants are delivered in the agent config

The grant rides `AgentConfigResponse.edge_output_grants`, the chunked, hashed config push. Its
window starts five minutes before the UTC day and ends eight days after the day starts, so a
spool backlog survives an outage of about a week, and Ed25519 signatures are deterministic, so
the config changes once a day or on an epoch move. A grant exists when the contract is active in
the installation registry and the agent's operator switch (the existing leasing setting, agent
then partition then global) is on. Turning the switch off revokes the grant and moves its epoch.

### Decision 3: One typed contract per producer and schedule

Each (data family, scheduling model) has exactly one typed output contract. A contract carries
the family's existing protobuf where one exists; a JSON producer gets a typed batch message
before it moves. The registry never admits an untyped status envelope.

- `serviceradar.metrics.batch`: every agent-scheduled `MetricBatch`, with no source
  authorization. That is sysmon, SNMP, ICMP, rperf, and MTR metrics; the status-interval sweep
  summary (the single newest group, leased or not); and the whole `MetricBatch` appended to each
  unleased sweep-results chunk. That chunk batch carries every series it has today:
  `sweep.total_hosts`, `sweep.available_hosts`, `sweep.sequence`, `sweep.port.*`,
  `sweep.host.*`, `sweep.scanner.*` from scanner_stats, and `sweep.banner_grab.*`.
  The summary moves with the other metrics producers and stays that newest-group sample. This
  change does not add a per-group interval emitter. The results-chunk batch moves with the
  unleased sweep results. A leased execution emits no metric batch of its own; the summary above
  is the agent's status-interval sample, not an execution batch. Core already stores that
  execution through the sweep projection. If per-host gauges for a leased sweep are needed later,
  core derives them from those projected results. That derivation is a follow-up, not this change.
- The frozen `SweepObservationBatchV1` and `MtrTraceBatchV1` bind each body to a per-run source
  authorization. Leased static sweep results keep `SweepObservationBatchV1` and that join.
  Unleased sweep results and agent-scheduled MTR traces get their own contracts that reuse the
  frozen host and trace sub-messages without that join. Every MTR trace, including a trace from
  a sweep group whose modes include mtr, is one of those agent-scheduled traces under the
  standing grant. It does not move with a sweep lease.

### Decision 4: One agent-side producer sink

Every migrated producer builds its record through one shared builder and appends to the spool,
which owns the record from then on ("append, then forget"). A retryable refusal keeps the batch
for retry within a bound; a drop is counted with its reason, never silent.

### Decision 5: Projectors write today's destinations

A registered projector writes what the legacy path writes for its contract. Where the legacy
destination is a JetStream subject (the `metrics.>` stream, logs, OTel), the one generic
republish projector republishes the attested batch there with PubAck and the record's event id
as `Nats-Msg-Id`, before its ledger transaction, so every existing consumer is unchanged and no
network call runs inside a database transaction. A replay or late-fenced delivery is not
republished. Telemetry storage follows the repository rule: StarRocks when enabled, CNPG
otherwise; flows and exposure stay StarRocks-only.

### Decision 6: Durable streams

The agent deletes a record once JetStream acknowledges it, so `TELEMETRY_EDGE_RECORD_V1_BULK` and
every stream a projector publishes to SHALL be replicated across the NATS cluster, and stream
reconciliation SHALL raise the replica count of an existing stream.

### Decision 7: One cutover release

Each producer moves behind the operator switch on exactly one path. It stops its status-path
emission only in the release where that producer emits as edge records, and only while the agent
holds that contract's grant. A producer that has not migrated keeps the status path even when the
agent already holds the grant, which is how the in-flight sysmon slice behaves. Holding
`serviceradar.metrics.batch` for sysmon does not take SNMP, ICMP, rperf, MTR, the periodic sweep
summary, or unleased sweep-results chunk batches off the status path. After each family's farm01
parity soak, the next release removes every legacy agent emission and the gateway's matching
publishers. The unleased sweep results contract and its payload are defined, shipped, and soaked
on farm01 before that release. Until then, cutover leaves `GetSweepResults`, the sweep results
KV, `serviceradar.sweep` on `StreamStatus`, and the gateway sweep publisher in place. Task 6
precedes task 8.
Order, by loss exposure and readiness:

1. Metrics: sysmon, then SNMP, ICMP, rperf and MTR metrics, then the newest-group status-interval
   sweep summary.
2. MTR traces.
3. Flow attribution and OTLP relay.
4. Plugin signals, native add-on telemetry, Wasm plugin results.
5. Unleased sweep results, together with the whole `MetricBatch` appended to each of those
   results chunks, onto `serviceradar.metrics.batch`.
6. Inventory producers: mapper, netprobe discovery, sync pages, workload identity, endpoint
   inventory, bumblebee, k8s endpoints.

### Decision 8: Adding a payload never touches the generic pipeline

The spool, sender, gateway authorization, JetStream route and EventWriter ledger are payload
agnostic and SHALL stay that way: the gateway never decodes a payload. The per-payload pieces are
kept to data plus, only where a destination is genuinely new, one projector module:

- **Projectors register by contract.** EventWriter selects a projector from a registry keyed by
  `{contract_id, contract_version}`; each projector implements one behaviour (decode and
  validate, authority re-check, project). There is no per-contract clause in the processor.
- **Republish projectors are configuration.** Metrics, logs and OTel all follow one pattern:
  re-check authority, attest from the authenticated record, republish to the subject the gateway
  uses today with PubAck. One generic republish projector, configured per contract (subject
  rule, attestation fields, accepted sources), serves them.
- **Grants follow the registry.** Core issues standing grants for every registry entry marked as
  agent-scheduled, rather than naming contracts in code.
- **Plugins and add-ons never get their own contract.** Native add-ons and Wasm plugins emit
  through the plugin telemetry contract (`TelemetryBatch`) and the plugin result contract.
  Routing keys off the SDK's closed TelemetryBatch payload kinds (`serviceradar_metrics`,
  `ocsf_event`, `otel_log`). Manifest `signal_schemas` only describe event and log schemas
  (`ocsf_event`, `otel_log`) and do not admit `serviceradar_metrics`. One projector routes each
  closed payload kind to its existing destination. A plugin author emits a closed payload kind
  and touches no core, gateway, registry, or manifest code. A new payload kind is an SDK and
  core change reviewed like any other contract.

So a new built-in family is a typed protobuf message, a registry entry and an agent producer,
plus a projector module only when its destination is new.

## Risks

- **Spool sharing.** All producers share one spool budget; admission backpressure and byte-fair
  lane interleaving (USP-01 2.7) are required before high-volume families move.
- **Grant expiry.** A record delivered after its grant expired is withheld until a delivery grant
  exists (USP-01 M2.0g); the eight-day window bounds that exposure.
- **Cutover risk.** One release removes every legacy path, so every family's soak must pass
  first; a family that cannot pass blocks the release rather than keeping a legacy fallback.
