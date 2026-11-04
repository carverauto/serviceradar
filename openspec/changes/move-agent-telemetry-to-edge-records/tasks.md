# Tasks: Move agent telemetry onto the durable edge-record pipeline

> **Reconciled against `staging` on 2026-11-02.** Each item is annotated DONE,
> PARTIAL or TODO. DONE items are checked, keep their original text, and cite
> their evidence. PARTIAL and TODO items stay unchecked with a one-line note of
> what remains.

## 1. Shared foundations

- [x] 1.1 Standing output grants: core issues, renews and revokes one capability per (agent,
  contract, epoch); delivered in the agent config; gateway trust snapshot carries the fences.
  Records under a grant carry no source authorization. Lease-signed `SweepObservationBatchV1`
  records stay on `serviceradar.sweep.observation` with the lease capability and
  `SCHEDULED_SWEEP`, and are not grant records.
  DONE (reconciled 2026-11-02): `ServiceRadar.Edge.OutputGrant` and `ServiceRadar.Edge.OutputGrants` issue, renew and revoke standing capabilities per `(agent, contract, epoch)`, delivered via `AgentConfigResponse.edge_output_grants` with fences carried in `ServiceRadar.Edge.RecordTrust.snapshot/1`; grant records carry no `source_authorization` while leased sweeps remain on `serviceradar.sweep.observation` (#6214, #6247).
- [x] 1.2 Agent producer sink: shared record builder, spool append with durable acknowledgement,
  retryable backpressure, counted drops.
  DONE (reconciled 2026-11-02): shared grant lookup, record builders, bounded retry queue and durable spool append with counted drops in `go/pkg/agent/edge_output_grants.go`, `go/pkg/agent/edge_record_emitter.go`, `go/pkg/agent/push_loop_metrics_edge.go` and `go/pkg/edge/edgerecord` (#6214, #6247, #6255).
- [ ] 1.3 Spool admission backpressure (USP-01 M3.2) and byte-fair lane interleaving (USP-01 2.7)
  before any high-volume family moves.
  PARTIAL (reconciled 2026-11-02): high/low-water pause landed as `unify-sweep-results-proto` M3.2 (#6269), and byte-fair admission across producer flows landed at the agent spool as USP-01 2.7 (#6274); remaining scope is the rest of USP-01 2.7.
- [x] 1.4 Replicate `TELEMETRY_EDGE_RECORD_V1_BULK` and the projector destination streams;
  reconciliation raises the replica count of an existing stream.
  DONE (reconciled 2026-11-02): `TELEMETRY_EDGE_RECORD_V1_BULK` and projector destination streams are configured for R3 replication, and `ServiceRadar.NATS.JetstreamConsumer` reconciles existing stream replica counts upward (#6219).
- [x] 1.5 EventWriter dispatch by output contract through a projector registry and behaviour;
  no per-contract clause in the processor.
  DONE (reconciled 2026-11-02): `ServiceRadar.Edge.Projector` behaviour and `ServiceRadar.Edge.ContractCatalog.projector/1` dispatch records in `ServiceRadar.EventWriter.Processors.EdgeRecord` without per-contract processor clauses (#6247).
- [ ] 1.6 One generic republish projector, configured per contract, for destinations that are
  JetStream subjects (metrics, logs, OTel).
  PARTIAL (reconciled 2026-11-02): `ServiceRadar.Edge.MetricsBatchProjection` republishes `serviceradar.metrics.batch` to `metrics.>` with `Nats-Msg-Id` and `PubAck` before ledger commit (#6214, #6247); remaining scope is OTLP relay and plugin/add-on log/event JetStream republish projection (tasks 4.1 and 5.1).
- [x] 1.7 Core issues standing grants for every registry entry marked agent-scheduled instead of
  naming contracts in code.
  DONE (reconciled 2026-11-02): `ServiceRadar.Edge.OutputGrants.config_grants/4` issues standing grants by reconciling each `ServiceRadar.Edge.ContractCatalog.standing_grant_refs/0` entry through `reconcile/4` (#6247).
- [x] 1.8 Generic dead-letter: a record of any contract whose projection keeps failing is copied
  with its original bytes and failure metadata to `TELEMETRY_EDGE_RECORD_DLQ_V1_BULK` before its
  source delivery is acknowledged, with a counter, managed alerts and a replay that republishes
  it through the ledger (`ServiceRadar.EventWriter.EdgeRecordDeadLetter`,
  `docs/edge-record-dead-letter-runbook.md`). The DLQ catalog, retention and redrive are
  `add-edge-record-stream-partitioning`.

## 2. Metrics

- [x] 2.1 Sysmon on `serviceradar.metrics.batch`: grant, agent producer, projector that
  republishes to the existing `metrics.>` subject, core NATS publish permission. Sysmon stops
  its status-path emission in this release while the agent holds the grant. SNMP, ICMP, rperf,
  MTR, the periodic sweep summary, and unleased sweep-results chunk batches keep the status path.
  DONE (reconciled 2026-11-02): sysmon emits `MetricBatch` records on `serviceradar.metrics.batch` via `go/pkg/agent/push_loop_metrics_edge.go` and stops legacy status-path emission while the grant is held; `ServiceRadar.Edge.MetricsBatchProjection` republishes to `metrics.sysmon.>` with core NATS publish ACL (#6214, #6247).
- [ ] 2.2 SNMP, ICMP, rperf and MTR metrics on the same contract. Each stops its own status-path
  emission only in the release that moves it, and only while the agent holds the grant.
  PARTIAL (reconciled 2026-11-02): SNMP, ICMP and MTR scalar metrics emit on `serviceradar.metrics.batch` via `go/pkg/agent/push_loop_metrics_edge.go` and stop legacy status-path emission while the grant is held (#6247); remaining scope is the rperf agent producer on `serviceradar.metrics.batch` and stopping its status-path `rperf-metrics` emission while the grant is held.
- [x] 2.3 Periodic sweep summary `MetricBatch` on `serviceradar.metrics.batch`, with no source
  authorization. It stays the status-interval sample of the single newest group, leased or not.
  Do not add a per-group interval emitter. This producer stops its status-path emission only in
  this release, and only while the agent holds the grant. A leased execution still emits no
  metric batch of its own.
  DONE (reconciled 2026-11-02): periodic sweep summary `MetricBatch` emits on `serviceradar.metrics.batch` via `sweepSummaryEdgeMetrics` in `go/pkg/agent/push_loop_metrics_edge.go` and `go/pkg/agent/push_loop_status.go` with no source authorization, stopping status-path emission while the grant is held and projecting to `metrics.sweep.>` (#6247).
- [ ] 2.4 farm01 parity soak against a control agent.
  TODO (reconciled 2026-11-02): remaining scope is the farm01 parity soak for `serviceradar.metrics.batch` against a control agent.

## 3. MTR traces

- [ ] 3.1 Agent-scheduled MTR trace contract reusing the frozen trace messages without a
  per-run source join. Every MTR trace, including a trace from a sweep group whose modes include
  mtr, moves here under the standing grant, with no sweep-lease dependency. Producer and projector
  into `mtr_traces`; parity soak.
  PARTIAL (reconciled 2026-11-03): the agent producer in `go/pkg/agent/push_loop_mtr_traces_edge.go` and `ServiceRadar.Edge.Projectors.ScheduledMtrTrace` store agent-scheduled checks from `serviceradar.mtr.scheduled_trace` v1 into `mtr_traces` while that grant is held (#6256 and this branch). Remaining scope is a trace from a sweep group whose modes include mtr, and the parity soak.

## 4. Flow attribution and OTLP relay

- [ ] 4.1 Contracts for `FlowAttributionEventBatch` and `OtlpRelayFrame`; producers and
  projectors; parity soak.
  PARTIAL (reconciled 2026-11-03): `FlowAttributionEventBatch` and `OtlpRelayFrame` contracts, per-row write budget and chunked observation publishing landed in `proto/agent/netprobe/v1/netprobe.proto`, `proto/agent/addon/v1/addon.proto` and `ServiceRadar.FlowAttribution.Observations` (#6262). The agent producers (`go/pkg/agent/push_loop_flow_attribution_edge.go`, `go/pkg/agent/addon_otlp_relay_edge.go`) and core projectors `ServiceRadar.Edge.Projectors.FlowAttribution` and `ServiceRadar.Edge.Projectors.OtlpRelay` landed on this branch; remaining scope is the parity soak.

## 5. Plugin and add-on telemetry

- [x] 5.1 `TelemetryBatch` contract for plugin signals and native add-on telemetry. Routing keys
  off the SDK's closed TelemetryBatch payload kinds (`serviceradar_metrics`, `ocsf_event`,
  `otel_log`, `discovery_v1`). `discovery_v1` is add-on-only; a plugin-stamped discovery record
  is refused. Manifest `signal_schemas` describe only event and log schemas (`ocsf_event`,
  `otel_log`). One projector routes each closed payload kind to its existing destination.
  Plugins and add-ons never get contracts of their own. A new payload kind is an SDK and core
  change.
  TODO (reconciled 2026-11-02): remaining scope is the `TelemetryBatch` contract catalog entry, agent producer, and core projector for `serviceradar_metrics`, `ocsf_event` and `otel_log`.
- [x] 5.2 Typed Wasm plugin result batch; producer and projector.
  DONE (reconciled 2026-11-03): `WasmPluginResultBatchV1` in `proto/edge/v1/plugin_results.proto` (#6245); agent producer in `go/pkg/agent/push_loop_plugin_results_edge.go` and projector `ServiceRadar.Edge.Projectors.WasmPluginResult` into `ServiceRadar.Observability.PluginResultIngestor`. Parity soak remains task 5.3.
- [ ] 5.3 Parity soak.
  TODO (reconciled 2026-11-02): remaining scope is the plugin and add-on telemetry parity soak after tasks 5.1 and 5.2.

## 6. Unleased sweep results

- [ ] 6.1 Sweep results contract for unleased groups, reusing the frozen host observation
  messages without a plan join; projector into today's sweep and inventory tables. The whole
  `MetricBatch` appended to each of those unleased results chunks moves in this same task onto
  `serviceradar.metrics.batch` with no source authorization, keeping every series it carries:
  `sweep.total_hosts`, `sweep.available_hosts`, `sweep.sequence`, `sweep.port.*`, `sweep.host.*`,
  `sweep.scanner.*`, and `sweep.banner_grab.*`. Define the contract and its payload, ship them,
  and pass the farm01 parity soak before cutover task 8.1.
  PARTIAL (reconciled 2026-11-02): `UnleasedSweepResultsBatchV1` contract in `proto/edge/v1/unleased_sweep.proto` (#6220), agent producer in `go/pkg/agent/push_loop_sweep_results_edge.go`, and `ServiceRadar.Edge.Projectors.UnleasedSweepResults` (#6255); remaining scope is the farm01 parity soak before task 8.1.

## 7. Inventory producers

- [x] 7.1 Typed batch contracts for mapper, netprobe discovery, sync pages, workload identity,
  endpoint inventory, bumblebee and k8s endpoints. Mapper, netprobe discovery, and sync pages
  are `proto/edge/v1/json_producer_batches.proto`. Workload identity, endpoint inventory,
  bumblebee, and k8s endpoints are `workload_identity.proto`, `endpoint_inventory.proto`,
  `bumblebee.proto`, and `k8s_endpoints.proto`, with checked-in Go and Elixir bindings.
  DONE (reconciled 2026-11-02): `MapperDeviceBatchV1`, `MapperInterfaceBatchV1`, `MapperTopologyBatchV1`, `MapperResultsBatchV1`, `NetprobeDiscoveryBatchV1` and `SyncPageBatchV1` in `proto/edge/v1/json_producer_batches.proto` (#6215), and `WorkloadIdentitySnapshotV1` in `proto/edge/v1/workload_identity.proto`, `EndpointInventoryScanPayloadV1` in `proto/edge/v1/endpoint_inventory.proto`, `BumblebeeScanPayloadV1` in `proto/edge/v1/bumblebee.proto` and `K8sPublicEndpointsSnapshotV1` in `proto/edge/v1/k8s_endpoints.proto` (#6215, #6221).
- [ ] 7.2 Producers and projectors; parity soak.
  TODO (reconciled 2026-11-02): remaining scope is the inventory agent producers, core projectors, and parity soak.

## 8. Cutover

- [ ] 8.1 One release removes every legacy agent emission and the gateway publishers that serve
  them. It follows task 6.1. It does not remove `GetSweepResults`, the sweep results KV,
  `serviceradar.sweep` on `StreamStatus`, or the gateway sweep publisher until the unleased sweep
  results contract and its payload are defined, shipped, and have passed the farm01 parity soak.
  This task also carries `unify-sweep-results-proto` M4.2, 7.4, 7.5 and the `GetSummary`
  delivery-ownership half of 2.1, which moved here on 2026-11-02.
  TODO (reconciled 2026-11-02): remaining scope is removing legacy agent emissions and gateway publishers after all producer families and their farm01 parity soaks complete.
- [ ] 8.2 Confirm no durable agent data remains on `StreamStatus`/`PushStatus`; only control
  traffic and ephemeral status summaries stay there.
  TODO (reconciled 2026-11-02): remaining scope is verifying after task 8.1 that only control traffic and ephemeral status summaries remain on `StreamStatus`/`PushStatus`.
