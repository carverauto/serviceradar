# Change: Stream flow attribution through an endpoint ownership index

## Why

Flow process attribution answers one question per flow endpoint: which process owned
`(partition, ip, port, proto)` at time T. Today the system answers it with a periodic global
join, and that join cannot reach fleet scale. Figures below are rounded and come from an
8-agent lab deployment.

- **Observations are periodic sightings, not changes.** Netprobe re-emits every cached socket
  on a 300 s heartbeat and on every fingerprint change, and never emits a close. The lab
  produced about 17.5M observation rows per day from 8 agents (about 2.2M per agent per day,
  about 25 rows/s per host) covering about 7.7M distinct socket tuples; one busy listener
  produced about 900 rows in 30 minutes. Extrapolated linearly to 20k agents that is about
  500k rows/s and about 44B rows/day, only to answer "who owned this endpoint".
- **The correlator has a hard throughput ceiling.** One pass every 120 s with `LIMIT 5,000`
  attributes at most about 42 flows/s. Selection is newest-first, so overflow is silently
  never attributed once it leaves the 15-minute flow window. A fleet of 8k-20k exporters at
  even 50 flows/s each is 400k-1M flows/s.
- **Every pass re-joins a fresh window.** Each pass joins up to 5,000 flows against 30 minutes
  of observations, so every observation is scanned about 15 times. At 20k agents one pass
  would read hundreds of millions of observation rows. The memory blowup seen at modest flow
  volume (a StarRocks compute-node limit of about 8.7 GB exceeded) came from the flows x
  observations join.
- **Write-back rewrites stored flows.** Every stamp is a partial primary-key update of a flow
  row that was already written.

Attribution is a key lookup, not a join. This change replaces the batch correlator with
streaming attribution: agents publish socket ownership changes, a central sharded index keeps
current and recent ownership by endpoint key, and flows are attributed on ingest with two key
lookups before their single StarRocks write.

## What Changes

- **Agents emit ownership changes, not sightings.** Netprobe publishes socket ownership
  leases keyed on the local endpoint: one open per new key, a slow renewal of each active lease
  (default 30 minutes) instead of the 300 s heartbeat, an explicit close when the kernel
  reports one, and a full snapshot on start. Accepted connections collapse onto their
  listener's lease unless their owner differs; when the listener closes or changes owner, its
  still-open accepted sockets are promoted to exact entries first. Wildcard listeners are expanded to the agent's
  own addresses, and the agent publishes its address set as address leases.
- **Ownership changes travel on JetStream.** Core keeps the existing bounded agent -> gateway
  -> core admission lane and publishes each admitted batch on `flows.ownership.<shard>` in a
  dedicated `flow_ownership` stream. Nothing writes ownership straight to a database.
- **A central endpoint ownership index.** In-memory index shards, hosted by the EventWriter
  flow tier and fed from their shard subject, map `(partition, proto, ip, port)` and an
  agent-scoped peer key to an owner (agent_id, pid, comm, redacted cmdline, uid, container_id,
  workload_identity), with a short validity history for time-T lookup. Shards rebuild from the
  stream on restart. Memory per shard is bounded and overflow is explicit.
- **Flows are attributed on ingest.** The EventWriter flow processor looks up the source and
  destination endpoints (batched per shard) and writes each flow once, already attributed.
  Public VIPs resolve to backends through a cached VIP map before the lookup. The existing
  precedence (exact, listener or relaxed UDP, node SNAT, public endpoint by exposure class) is
  preserved as lookup order.
- **Bounded late binding.** A flow whose endpoint is monitored (an agent address, or a public
  VIP whose mapped backend is) but has no owner yet is
  held for a few seconds. If it is still unmatched it is written unattributed and kept in a
  bounded set of per-flow decision states; every flow with a monitored side, attributed or
  not, keeps its decision state open for the late window, except under the flagged
  budget degradation. A late ownership event stamps those flows through the existing
  `events.flow.attribution` update. Nothing re-scans flows.
- **Host-observed connection summaries.** Because accepted connections collapse onto their
  listener's lease, netprobe also emits bounded per-interval summaries per process, local
  endpoint and peer (counts, first and last seen, optional bytes and packets). They travel on
  JetStream and are appended to a StarRocks evidence table for host-only exposure queries and
  for spotting network-observed connections no host saw (#5745). Over a per-agent budget they
  are merged in stages down to a per-direction overflow row, so the cap is strict, and every
  merge is counted; nothing is silently dropped. The ownership index does not use them.
- **Late decisions do not depend on arrival order.** For a flow whose decision state lasts
  its full late window, the final decision is a function of the candidates the home shard
  processed by the window's cutoff. The home shard recomputes it on every change to that set (new leases, delayed
  closes, expiry) and publishes whenever it changes, including evidence-only updates for newly
  found ambiguity; updates are ordered by a per-flow decision sequence. If the decision-state
  budget binds, the oldest states finalize early and are flagged and counted.
- **Agent-local attribution stays primary** for flows an agent produces itself. The index serves
  flows from routers and other exporters.
- **Ownership history for incident response** moves from the sighting table to an append-only
  lease history table, one row per ownership event (`OPEN`, `RENEW`, `CLOSE`, `SNAPSHOT`
  entry), so a long-lived lease adds one renewal row per renewal period, under the existing
  `attribution` retention dataset.
- **Capacity targets become requirements:** at least 1M flows/s attributed across horizontally
  scaled consumers, ownership ingest from 20k agents, bounded memory per shard, and an
  attribution latency budget.
- **BREAKING (internal):** delete the batch correlator (`FlowAttribution.Correlator`,
  `FlowAttribution.Correlation`, `PassMetrics`), the `flows.attribution.observations` subject,
  the `FlowAttributionObservations` processor and the StarRocks table
  `flow_process_attribution_observations`, and the netprobe heartbeat and resend paths. This is a
  straight switch with no dual-write or backfill, following the precedent of
  `move-flow-attribution-to-starrocks`. Attribution state is ephemeral, and flows already require
  StarRocks (`AGENTS.md`: `in:attributed_flows` returns `{:error, :starrocks_required}` without
  it).
- **Admission lane:** the existing bounded flow-attribution lane carries ownership batches. Its
  completion point becomes the JetStream acknowledgement, not a database commit, and its worker
  count becomes configurable so ownership ingest can scale with the fleet.
- **Interim mitigation:** the unmerged branch `fix/flow-attribution-correlator-memory` bounds
  the current statement's memory (backend-first VIP join, `min_by` winner selection, pass
  backoff). It keeps the correlator usable until this change ships. It does not lift the
  throughput ceiling.

## Impact

- Affected specs: `flow-attribution`.
- Affected code:
  - Netprobe: `rust/netprobe/src/attribution.rs` (cache, heartbeat, resend, close handling,
    lease emission), `proto/agent/netprobe/v1/netprobe.proto` (ownership lease messages).
  - Agent: `go/pkg/agent/push_loop_flow_attribution.go` and `go/pkg/agent/netprobe/`
    (ownership batches over the existing retained delivery path).
  - Core: `ServiceRadar.FlowAttribution` and its `Observations`, `EventRows`, `Correlation`,
    `Correlator`, `PassMetrics` modules; the `StatusHandler` flow-attribution branch; a new
    ownership publisher and index; `ServiceRadar.EventWriter.Processors.Flows`,
    `FlowAttributionObservations`, `FlowAttributionUpdates`; `EventWriter.Config` and
    `Pipeline`; `Cluster.CoordinatorChildren` (EventWriter workers, the shared Pipeline and
    FlowPipeline, run on every serviceradar-core replica bound to shared durables; only
    ConsumerReconciler, the lag reporter, the flow correlator, and the six single-writer
    streams run under `EventWriter.CoordinatorSupervisor`).
  - Warehouse DDL: `elixir/serviceradar_core/priv/starrocks/` (drop the observations table, add
    the lease history table); `Analytics.StarRocks.{Destination,Rows,Retention}`.
  - Helm: NATS stream and permissions for `flows.ownership.*`, and EventWriter flow-tier
    replicas and shard placement.
- Tracking: [#5738](https://github.com/carverauto/serviceradar/issues/5738). Depends on this:
  [#5745](https://github.com/carverauto/serviceradar/issues/5745) (exposure intelligence), which
  needs the per-process connection summaries.
- Related: `move-flow-attribution-to-starrocks` (archived; superseded here),
  `harden-flow-attribution-pipeline` (archived; the precedence and admission lane are kept),
  `add-netprobe-fleet-attribution` (event-driven netprobe inventory, which this builds on),
  `scale-netflow-ingest-isolation` (dedicated flow stream and demand domain),
  `add-k8s-public-endpoint-inventory` (VIP source), `add-workload-identity-enrichment`
  (workload identity source), `improve-attributed-flow-investigation` (reads the same
  attribution columns, unchanged).
