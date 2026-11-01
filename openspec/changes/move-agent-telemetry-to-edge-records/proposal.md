# Change: Move agent telemetry onto the durable edge-record pipeline

## Why

USP-01 (`unify-sweep-results-proto`) built a durable, binary producer pipeline:
agent spool, signed edge records, gateway authorization, JetStream PubAck before
the agent may reclaim, and an idempotent EventWriter ledger. On farm01 it has
carried leased static sweeps for 48 hours with zero loss and survived restarts of
the gateway, core, NATS, and the agent mid-delivery (M3.3).

Every other kind of agent data still travels over `StreamStatus`/`PushStatus`,
and most of it can be lost today:

- Sysmon, SNMP, ICMP checks, MTR, mapper and netprobe discovery, native add-on
  telemetry, and plugin signals are drained from their in-memory buffers BEFORE
  the send succeeds. A failed send loses them.
- The gateway publishes metric sources with Core NATS `pub` and no PubAck, so a
  send the agent saw succeed can still be lost between the gateway and JetStream.
- The gateway fallback buffer for forwarded results is in memory, holds 100
  entries, and drops the oldest when full.
- Several producers still ship JSON inside the status envelope.

The pipeline was always meant to be shared. The USP-01 backlog (tasks 2.10-2.14)
names the producer sink, Wasm, native add-on and integration adapters, but they
were deferred to prove the transport on one producer first. That proof is done.

## What Changes

- Add one typed output contract per source-authorization rule. Each carries an
  EXISTING protobuf as its payload where one exists (`metric.v1.MetricBatch`,
  `addon.v1.TelemetryBatch`, `addon.v1.OtlpRelayFrame`,
  `netprobe.v1.FlowAttributionEventBatch`, `edge.v1.MtrTraceBatchV1`). Metrics
  uses two contracts with that one `MetricBatch` payload, one projector, and one
  destination: `serviceradar.metrics.batch` v1 for passive producers (sysmon and
  any other passive metric producer; standing grant; no source authorization) and
  `serviceradar.metrics.scheduled` v1 for lease-run metrics (`SCHEDULED_CHECK` for
  SNMP, ICMP, and MTR metrics and rperf; `SCHEDULED_SWEEP` for sweep metric
  batches). JSON-only producers get a typed batch contract before they move.
- Add two core-signed grant models, both expressible in the frozen record ABI with
  no ABI change:
  - **Check leases** for producers core schedules (MTR, ICMP checks, SNMP polls,
    plugin runs, sync runs, mapper jobs): a production capability plus a
    `SCHEDULED_CHECK` or `INTEGRATION_RUN` source authorization, mirroring sweep
    leases. Sweep metric batches on `serviceradar.metrics.scheduled` v1 keep
    `SCHEDULED_SWEEP` under the existing sweep lease. SNMP, ICMP, and MTR metrics
    and rperf on that contract carry `SCHEDULED_CHECK`.
  - **Standing output grants** for passive producers (sysmon on
    `serviceradar.metrics.batch` v1, add-on telemetry, OTLP relay, flow
    attribution, netprobe discovery, workload identity): a renewable production
    capability per (agent, contract) with no source authorization, fenced by an
    authority epoch.
- Add one agent-side producer sink that every migrated producer appends to,
  replacing drain-before-send buffers. Admission is acknowledged only after the
  record is fsynced to the spool.
- Add one EventWriter projector per contract. The two metrics contracts share
  one projector. Each projector writes the same destination the legacy path
  writes today (`timeseries_metrics`, `mtr_traces`,
  OTel/log processors, flow attribution in StarRocks, inventory ingestors), inside
  the existing ledger transaction so redelivery changes nothing.
- Soak producers one family at a time behind a per-agent opt-in, with one path
  per producer at a time (never both). The next release removes legacy agent
  status-path emission and the gateway's matching publishers together, after
  every sweep group that has hosts and an ICMP or TCP check has a signed sweep
  lease. A nothing-to-scan group counts as satisfied. There is no long-lived
  per-family legacy.
- Move sweep groups that use a `target_query` in a final phase, before that
  cutover. The signed plan is `SweepCompiler`'s target resolution for that group,
  the same function the compiler uses today: `normalize_target_query` partition
  scoping (`SRQLQuery.ensure_target/2` prepends `in:devices` only when the trimmed
  query does not already start with `in:`), the alias filters (strict IP,
  `alias_type` ip, confirmed, updated, or
  detected, AliasRecency window, not already a primary, capped at
  `sweep_max_alias_targets_per_device`), per-row drops of non-address values (a
  CIDR in the ip column is not planned as a prefix), plus the group's static
  targets, under the existing sweep lease and `SCHEDULED_SWEEP`. A successful
  read whose targets differ, and that still has hosts and an ICMP or TCP check,
  re-plans. A set that exceeds plan limits is split
  across executions or ranges. A failed device read, including a later page error
  or an alias-table error, keeps the last signed plan and does not sign a partial
  page set or a plan that omits aliases. An unparseable query, and a query that
  parses but cannot be translated or cast, contributes no hosts and does not keep
  the last plan; static targets still run when an ICMP or TCP check remains.
  When that leaves no hosts, or a successful resolution plus static
  targets yields no hosts, or modes leave no ICMP or TCP sweep check
  (mtr only, tcp or tcp_connect with no ports, or only modes SweepCompiler
  drops), core does not sign an empty plan: it withdraws the sweep lease with a
  revoked SweepLeaseV1, records an operator-visible nothing-to-scan state, and
  signs again when a later resolution or edit yields hosts and an ICMP or TCP
  check. A failed read still keeps the last signed plan. An mtr-only group's
  traces run under MTR check leases with no sweep lease. Sweep results and the
  sweep metric batch move together once a sweep lease exists.
- Give every sweep group that has hosts and an ICMP or TCP check a lease before
  that same cutover. Lower the lease schedule minimum from 300 seconds to 1
  second, so a whole-second interval leases; the cost is more slots per horizon.
  A group whose modes include mtr is not refused. When an ICMP or TCP check
  remains, reachability and port results stay on the sweep lease. An mtr-only
  group has no sweep lease; its traces are `MtrTraceBatchV1` under MTR check
  leases. Banner results are a new typed output
  contract under that same sweep lease and `SCHEDULED_SWEEP`;
  `EdgeRecordV1` and the frozen payloads stay unchanged. A CIDR in a query ip
  column is dropped for that row. A static target the plan builder cannot
  represent, such as an IPv6 prefix wider than /65 (`:target_too_wide`), is
  refused at sweep group configuration with an operator-visible validation error.
  An existing group of that kind is reported as not runnable and does not run on
  the legacy path.

## Out of Scope

- RTSP and other live media streams: they are not records.
- Control traffic: hello, config, control stream commands and acks, sweep lease
  acks, certificate renewal, credential grants, KV, artifact transfer.
- Ephemeral latest-wins status summaries (agent health, service status signature
  heartbeats, plugin-engine counters). Per USP-01 task 2.14 these stay on
  `GatewayServiceStatus`.

## Impact

- Affected specs: `edge-producer-data-plane` (new contract, grant, sink and
  migration requirements).
- Affected code: `go/pkg/agent` push loops and buffers, `go/pkg/edge` (sink,
  contracts), `go/cmd/agent` sender wiring, agent-gateway contract registry and
  authorization, core issuer/lease/grant modules, `LeaseSchedule` minimum,
  SweepPlan mtr handling, sweep-lease withdrawal when nothing remains to scan,
  the banner-results contract, EventWriter projectors,
  Helm contract registry values.
- Depends on: `unify-sweep-results-proto` (pipeline, spool, sender, gateway relay,
  ledger), which stays the runtime change of record for the shared transport.
