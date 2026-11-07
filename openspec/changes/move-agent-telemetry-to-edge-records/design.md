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
Superseded by `enable-edge-record-pipeline-by-default` (Decision 1): the switch is removed, the
registry is derived by core, and a grant exists whenever the contract is active in the active
epoch and the agent's partition resolves.

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
  `ocsf_event`, `otel_log`, `discovery_v1`). `discovery_v1` is admitted only from a native add-on;
  a plugin-stamped discovery record is refused, because Wasm plugins reach inventory through the
  plugin-result route. Manifest `signal_schemas` only describe event and log schemas
  (`ocsf_event`, `otel_log`) and do not admit `serviceradar_metrics`. One projector routes each
  closed payload kind to its existing destination. A plugin author emits a closed payload kind
  and touches no core, gateway, registry, or manifest code. A new payload kind is an SDK and
  core change reviewed like any other contract.

So a new built-in family is a typed protobuf message, a registry entry and an agent producer,
plus a projector module only when its destination is new.

### Decision 9: Without a grant a producer holds, it never falls back (agent cutover, 2026-11-04)

The cutover release removes every agent emission of durable data from `StreamStatus` and
`PushStatus`. The agent no longer has a `StreamStatus` client at all; `PushStatus` carries only
service status summaries, the agent capability status and the plugin-engine counters. A producer
that holds no standing grant for its contract (before the first config, after a revocation, a
partition with no row) or has no spool (`spool_unavailable`) treats that exactly like a retryable
spool refusal: it back-pressures, as `enable-edge-record-pipeline-by-default` Decision 1 states.
It never sends on the status path and never drops silently. Concretely:

- Producers whose source overwrites or drops on its own (sysmon and SNMP ring buffers, ICMP check
  results, the sweep summary sample, plugin telemetry signals) keep draining into the bounded
  queue they already use under spool refusal. Overflow drops the oldest entries and is counted as
  `agent_edge_record_dropped_samples_total{reason="awaiting_grant"}`.
- Producers whose source holds or back-pressures on its own are not read: Wasm plugin results (the
  plugin manager's queue makes executions wait), mapper and netprobe discovery, flow attribution
  (the sidecar counts its channel drops and the next batch reports them in `dropped_since_last`),
  workload identity, k8s public endpoints, endpoint inventory and bumblebee (latest-wins snapshots
  on disk or in the service), unleased sweep results (the sweep service keeps its completed
  cycles), the OTLP relay (the pump stops pulling; frames stay unacked in the add-on's durable
  spool), and rperf (one drained metrics status is held unbuilt and polling pauses). MTR checks do
  not run without both the metrics and scheduled trace grants, and a sync run does not start
  without the sync page grant (a page whose grant disappears mid-run fails the run).
- Leased sweep slots wait unconsumed while the spool is unavailable.
- Each push cycle a producer holds for want of a grant is counted as
  `agent_edge_record_grant_holds_total{producer}`, so a missing grant is visible on the agent as
  well as through core's `partition_not_found` and `spool_unavailable` conditions.
- Records already built under an earlier grant finish under that grant before anything new is
  read, as a response with records in the spool already did.

Data the edge path cannot carry is counted, not rerouted: an unleased sweep results response that
does not form a typed batch, or whose first record the spool refuses permanently, is dropped,
counted and acknowledged; an OTLP relay record larger than any edge record is counted and acked.

The farm01 parity soaks of tasks 2.4 to 7.2, including the unleased sweep results soak named in
task 8.1 and the requirement "Each producer emits on one path and legacy is removed at cutover",
are release gates under `enable-edge-record-pipeline-by-default` Decision 13 (task 7.2 there): the
release candidate that carries this removal is what M4.1 soaks on farm01. The code therefore lands
before the soak; the release is not cut until the soaks pass.

#### Gateway half: the status RPCs refuse durable data and count it per agent (2026-11-04)

The cutover release removes every gateway publisher that served durable agent data on
`StreamStatus`/`PushStatus`, including the gateway sweep publisher and `serviceradar.sweep`
results: the unleased sweep results contract shipped (#6255, #6302), and the family soaks are
release gates (the farm01 M4.1 run of the release candidate,
`enable-edge-record-pipeline-by-default` Decision 13), not code gates. With the gateway
forwarding only summaries, core's durable status ingest (the flow, retained-plugin, sweep and
result lanes, `SweepQueue`, `ResultsRouter`) receives nothing; deleting it is tracked in task 8.1.
The LargeIngestionGate release qualification was rebased onto edge records first (#6339 Part 1),
so it no longer runs on that tree.

What stays on the status RPCs is ephemeral and latest-wins: source `status` (service health
heartbeats, including the `agent` capability status core reads add-on state from) and
`plugin-telemetry` (plugin-engine counters). Control traffic (hello, config, control stream,
leases, certificates, credential grants, artifacts) never used these RPCs. RTSP and live media
are untouched.

An agent built before the cutover still sends durable data there. The gateway
(`ServiceRadarAgentGateway.RetiredStatusSources`) does not publish, forward or buffer it, and it
does not drop it silently:

- It counts each refused status per agent and bounded source family in the agent tracker
  (`ServiceRadar.AgentTracker.record_refused_statuses/2`) and as the gateway metric
  `serviceradar_agent_gateway_status_retired_source_refused_count{source}`, and logs the first
  refusal per agent.
- The existing per-agent condition `agent_upgrade_pending`
  (`ServiceRadar.Edge.PipelineReadiness`) now also holds for an agent the gateway refused
  anything from, with `refused_statuses` and `last_refused_at` in its detail. It shows in the
  readiness report, the agent API and the agent detail page. No parallel mechanism is added.
- The RPC answers `received: false` when every status in it was refused and never fails: a
  status RPC error makes the agent tear down its gateway connection, and with it the control
  stream that delivers the upgrade.

A status summary is refused whole when its message exceeds 4 KiB; it is never cut. It is counted
like a retired source, under the family `oversized_summary`.

The PushStatus response still carries the endpoint inventory directives the agent applies. A
scan used to produce its `endpoint_inventory.reconcile_floor` directive from its own status-path
ingest result; scans now arrive only as edge records, whose acknowledgement carries nothing back
to the agent. So on the push carrying the agent capability status (once per status interval)
the gateway asks core (`AgentGatewaySync.status_directives/1`), which reads the agent's current
scan as the projection recorded it and requests a full upload while that scan has reached the
floor. The request repeats each interval until the full upload is projected and clears the
floor; the agent keeps only the newest request, so a repeat costs at most one extra full upload
when it races the projection. No agent or proto change is involved.

## Risks

- **Spool sharing.** All producers share one spool budget; admission backpressure and byte-fair
  lane interleaving (USP-01 2.7) are required before high-volume families move.
- **Grant expiry.** A record delivered after its grant expired is withheld until a delivery grant
  exists (USP-01 M2.0g); the eight-day window bounds that exposure.
- **Cutover risk.** One release removes every legacy path, so every family's soak must pass
  first; a family that cannot pass blocks the release rather than keeping a legacy fallback.
