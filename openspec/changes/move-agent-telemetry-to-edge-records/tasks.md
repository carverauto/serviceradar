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
- [x] 2.2 SNMP, ICMP, rperf and MTR metrics on the same contract. Each stops its own status-path
  emission only in the release that moves it, and only while the agent holds the grant.
  DONE (reconciled 2026-11-03): SNMP, ICMP, rperf and MTR scalar metrics emit on `serviceradar.metrics.batch` via `go/pkg/agent/push_loop_metrics_edge.go` and `go/pkg/agent/push_loop_status.go` and stop legacy status-path emission while the grant is held, with `ServiceRadar.Edge.MetricsBatchProjection` republishing onto `metrics.snmp.>`, `metrics.icmp.>`, `metrics.rperf.>` and `metrics.mtr.>` (#6247 and this branch).
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
  PARTIAL (reconciled 2026-11-03): the agent producer in `go/pkg/agent/push_loop_mtr_traces_edge.go`, sweep-group MTR check derivation in `go/pkg/agent/mtr_checker.go` (with `mtr` ignored by `ServiceRadar.Edge.SweepPlan.checks/2` so reachability and port checks stay eligible for sweep leases), and `ServiceRadar.Edge.Projectors.ScheduledMtrTrace` store agent-scheduled checks and sweep-group MTR traces from `serviceradar.mtr.scheduled_trace` v1 into `mtr_traces` while that grant is held (#6256, #6284 and this branch). Remaining scope is the parity soak.

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
  DONE (reconciled 2026-11-03): `serviceradar.telemetry.batch` v1 catalog entry in `ServiceRadar.Edge.ContractCatalog`, agent producer in `go/pkg/edge/edgerecord/telemetry_batch.go` and `go/pkg/agent/push_loop_telemetry_edge.go`, and core projector `ServiceRadar.Edge.Projectors.TelemetryBatch` routing `serviceradar_metrics`, `ocsf_event`, `otel_log`, and add-on `discovery_v1` while refusing plugin-stamped `discovery_v1` (#6264). Parity soak remains task 5.3.
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
  PARTIAL: mapper devices/interfaces/topology, netprobe discovery and sync pages now have
  standing-grant contracts (`serviceradar.mapper.devices.batch`,
  `serviceradar.mapper.interfaces.batch`, `serviceradar.mapper.topology.batch`,
  `serviceradar.netprobe.discovery.batch`, `serviceradar.sync.page.batch`), agent producers on
  the shared emitter, and core projectors that rebuild the legacy payloads into the same
  ingestors. Workload identity snapshots have `serviceradar.workload_identity.snapshot`, an
  agent producer in `go/pkg/agent/push_loop_workload_identity_edge.go`, and
  `ServiceRadar.Edge.Projectors.WorkloadIdentity` writing through
  `ServiceRadar.WorkloadIdentity.persist_snapshot/1`. K8s public endpoints have
  `serviceradar.k8s.public_endpoints.snapshot`, an agent producer in
  `go/pkg/agent/push_loop_k8s_public_endpoints_edge.go`, and
  `ServiceRadar.Edge.Projectors.K8sPublicEndpoints`. Endpoint inventory has the standing-grant
  contract `serviceradar.endpoint_inventory.scan`, an agent producer and the `EndpointInventory`
  projector writing through `EndpointInventoryIngestor`. Bumblebee scans have
  `serviceradar.bumblebee.scan` v1 with an agent producer and the `BumblebeeScan` projector
  writing through `BumblebeeIngestor`. Remaining scope is the parity soak.

## 8. Cutover

- [ ] 8.1 One release removes every legacy agent emission and the gateway publishers that serve
  them. It follows task 6.1. It does not remove `GetSweepResults`, the sweep results KV,
  `serviceradar.sweep` on `StreamStatus`, or the gateway sweep publisher until the unleased sweep
  results contract and its payload are defined, shipped, and have passed the farm01 parity soak.
  This task also carries `unify-sweep-results-proto` M4.2, 7.4, 7.5 and the `GetSummary`
  delivery-ownership half of 2.1, which moved here on 2026-11-02.
  PARTIAL (2026-11-04): the agent half is done (8.1.1); the gateway publishers and core
  status-path consumers remain (8.1.2). The family soaks gate the release cut, not this code
  (design Decision 9).
  - [x] 8.1.1 Agent: remove every legacy agent emission of durable data, including unleased sweep
    results on `serviceradar.sweep`, the leased-slot run without a spool, and every
    fallback-to-legacy branch. A producer without a grant or spool holds its data (design
    Decision 9). `GatewayClient.StreamStatus` is deleted, so the agent cannot open a
    `StreamStatus` stream. The agent stops advertising `plugin-result-retained:v1` and stops
    filling `GatewayStatusRequest.endpoint_inventory_standing_question_counts`.
    `SweepService.GetSweepResults` stays: it is the agent-internal source the unleased sweep
    results producer reads.
  - [ ] 8.1.2 Gateway and core: remove the `StreamStatus` handler's durable-data publishers and
    the status-path ingestors for every family listed in 8.2, the sweep results KV and the
    gateway sweep publisher. Endpoint inventory reconcile-floor directives were built from the
    ingest result of a status-path scan; with scans only on edge records no directive is produced
    any more, so core needs another carrier for that request (the agent still applies any
    `endpoint_inventory.*` directive a `PushStatus` response carries).
- [ ] 8.2 Confirm no durable agent data remains on `StreamStatus`/`PushStatus`; only control
  traffic and ephemeral status summaries stay there.
  PARTIAL (2026-11-04): agent side confirmed. The agent opens no `StreamStatus` stream, and
  `PushStatus` carries only service status summaries (sweep, SNMP target and checker statuses),
  the agent capability status and the plugin-engine counters (`plugin_engine`), all latest-wins.
  No longer sent by the agent: sources `sysmon-metrics`, `snmp-metrics`, `icmp-metrics`,
  `mtr-metrics`, `rperf-metrics`, `sweep-metrics`, `results` (sweep, mtr_traces, mapper,
  mapper_interfaces, mapper_topology, passive netprobe, sync), `flow-attribution`,
  `workload-identity`, `plugin-result`, `plugin:<id>`, `addon:<id>`, `otlp-relay`, and the
  endpoint inventory, bumblebee and k8s public endpoints service payloads. Remaining: the gateway
  half of 8.1.2.
