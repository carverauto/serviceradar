## 0. Measure and spike (gate before build work)
- [ ] 0.1 On the lab, split current observation tuples into accepted (inbound, covered by a listener lease) and outbound (one lease each), and record active local keys per host. Project the per-host ownership event rate under Decision 1. Gate: median <= 5 events/s per host; otherwise revisit renewal period and close coalescing before 1.x.
- [ ] 0.2 Spike the shard store: ETS with packed binary keys and interned owners, at 2.5M keys per shard. Measure bytes per key (including 4 history slots), batched lookup rate, and apply rate. Gate: <= 200 bytes per key; otherwise move the store into a Rust NIF behind the same interface.
- [ ] 0.3 Measure replay time of 45 minutes of synthetic ownership events for one shard (2.5M keys). Gate: ready <= 2 minutes.
- [ ] 0.4 Record the results in this change's design.md, rounded, with no live hostnames, addresses or cluster names.

## 1. Netprobe: ownership leases
- [ ] 1.1 Extend `proto/agent/netprobe/v1/netprobe.proto`: `lease_op`, `first_seen_unix_nano`, `last_seen_unix_nano`, `ttl_seconds`, `closed` on `FlowAttributionEvent`; `AddressLease` and `snapshot_complete` on `FlowAttributionEventBatch`. Regenerate Go, Rust and Elixir bindings.
- [ ] 1.2 Key leases on the local endpoint in `rust/netprobe/src/attribution.rs`. Accepted sockets with the listener's owner emit nothing; a differing owner emits an exact peer entry.
- [ ] 1.3 Emit `CLOSE` on TCP close and close-state transitions. Coalesce `OPEN` + `CLOSE` within one batch window into one event.
- [ ] 1.4 Replace the 300 s raw heartbeat and the resend path with a jittered `RENEW` per renewal period (default 30 minutes).
- [ ] 1.5 Expand wildcard listeners per local address. Publish address leases, and re-expand on address change.
- [ ] 1.6 Emit `SNAPSHOT` on start and on agent reconnect.
- [ ] 1.7 Add the per-agent event budget with ordered shedding and shed counters by reason.
- [ ] 1.8 Unit tests per scenario of *Agents Emit Socket Ownership Leases Instead Of Sightings*, and an extension of the loaded-kernel TCP gate to assert `OPEN` and `CLOSE` for a real loopback connection.
- [ ] 1.9 Bump the netprobe add-on manifest version and Bazel `NETPROBE_VERSION` together.

## 2. Agent and core ingest
- [ ] 2.1 Agent push loop (`go/pkg/agent/push_loop_flow_attribution.go`): carry lease ops, address leases and snapshots in the existing retained batches; batch window default 5 s.
- [ ] 2.2 Core admission lane: reply after JetStream acknowledges every message of the unit; make worker count configurable (default 1); update lane tests for the modified requirement.
- [ ] 2.3 Ownership publisher: normalize addresses, compute buckets on `(partition, ip)`, derive node-SNAT peer entries from registered agent node IPs, split by bucket under the existing row and byte caps. Decode events without `lease_op` as `OPEN` with a 10-minute TTL.
- [ ] 2.4 Create the `flow_ownership` stream (`flows.ownership.<bucket>`, 256 concrete leaves, `max_age` 45 minutes) with flow-owned limits. Assert no subject overlap with the `flows` stream.
- [ ] 2.5 Helm: NATS permissions for core publish and EventWriter subscribe on `flows.ownership.*`, and stream sizing values.

## 3. Ownership index
- [ ] 3.1 Shard store: endpoint keys, peer keys, address presence, a 4-slot validity history, an interned owner table, and workload identity resolved per owner record from the CNPG cache.
- [ ] 3.2 Time-T lookup with skew tolerance and the deterministic tie-break with ambiguous counting.
- [ ] 3.3 Expiry through a timer wheel; history horizon for closed leases; `SNAPSHOT` replaces an agent's leases.
- [ ] 3.4 Entry and byte budgets per shard, with ordered refusal and counters.
- [ ] 3.5 Shard ownership and placement on top of the existing lease and coordinator machinery: active owner, optional warm standby, bucket-range rebalancing, and full-replica placement for single-node and small installs.
- [ ] 3.6 Rebuild by replay; `index_warming` until caught up.
- [ ] 3.7 Batched lookup API (one call per shard per flow batch): a local call when co-located, a distributed call otherwise.
- [ ] 3.8 Tests per scenario of *Endpoint Ownership Index Is Keyed Sharded And Bounded*.

## 4. Attribution on ingest
- [ ] 4.1 Allow the EventWriter flow pipeline (and the index shards) to run on every flow-tier node against the shared durable pull consumer. The rest of EventWriter stays coordinator-only.
- [ ] 4.2 Public endpoint map cache from `public_endpoints_current`, refreshed on change.
- [ ] 4.3 Attribution step in `Processors.Flows`: keys for both sides, VIP rewrite, batched lookups, the precedence table, the cross-side tie-break, and a single write with `attributed_flow` and owner columns. Keep agent-provided attribution for the side the agent owns.
- [ ] 4.4 Hold buffer with item and byte caps, deadline below `ack_wait`, shard notification on `OPEN`, and no hold for unmonitored flows.
- [ ] 4.5 Late-stamp set per shard (window, entry cap, eviction counters), publishing versioned updates on `events.flow.attribution`, with versions fetched in batches.
- [ ] 4.6 Tests per scenario of *Flows Are Attributed On Ingest By Key Lookup*, *Late Binding Is Bounded And Never Rescans Flows*, *Agent-Local Attribution Takes Precedence* and the modified *Correlation Is Protocol-Aware And Exact-First*.

## 5. Lease history
- [ ] 5.1 StarRocks DDL for `flow_ownership_leases` (Duplicate Key, daily partitions) in `elixir/serviceradar_core/priv/starrocks/`.
- [ ] 5.2 EventWriter processor that appends one row per ownership event; map the `attribution` retention dataset to the new table.

## 6. Health
- [ ] 6.1 Index and enrichment metrics on the JetStream metrics pipeline with bounded labels.
- [ ] 6.2 Per-interval diagnostics (`attributed`, `held`, `late_stamped`, `unmonitored`, `no_owner`, `ambiguous`, `index_warming`, `error`, `no_producer`, `no_flows`) replacing the per-pass outcomes; update the attribution health surface.

## 7. Capacity verification
- [ ] 7.1 Synthetic load harness using only invented data from documentation ranges (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24, 2001:db8::/32): simulated agents, ownership events, and flows.
- [ ] 7.2 Throughput run: >= 1M flows/s at the attribution stage, and >= 1.6x when flow-tier nodes are doubled, up to the warehouse write limit.
- [ ] 7.3 Ownership ingest run: 20k simulated agents for 1 hour; zero acknowledged loss; lag p99 <= 5 s.
- [ ] 7.4 Memory run: 40M active keys at <= 200 bytes per key, with every shard within budget; rebuild of a 2.5M-key shard <= 2 minutes.
- [ ] 7.5 Latency run: p99 added latency <= 250 ms per batch; holds within the window; late stamps within 60 s.

## 8. Cutover and removal (same release as 1-6)
- [ ] 8.1 Delete `FlowAttribution.Correlator`, `FlowAttribution.Correlation`, `PassMetrics`, the correlator kill switch and its supervisor wiring.
- [ ] 8.2 Delete `FlowAttribution.Observations`, the `FlowAttributionObservations` processor, `flows.attribution.observations` from the `flows` stream, EventWriter config and NATS permissions, and the StarRocks DDL for `flow_process_attribution_observations` (add a drop statement).
- [ ] 8.3 Remove the netprobe heartbeat and resend configuration (`DEFAULT_FLOW_ATTRIBUTION_RESEND_INTERVAL_S`, `FLOW_ATTRIBUTION_RAW_HEARTBEAT_INTERVAL`).
- [ ] 8.4 Search the workspace for every removed module, subject and table name (including tests, Helm, docs and `openspec/notes/`), and leave no dangling reference.
- [ ] 8.5 Post-rollout verification on the lab per the modified *Post-Rollout Verification Proves The Committed Artifact Chain*, gating on rows written after the rollout completed.

## 9. Documentation
- [ ] 9.1 Update `docs/docs/netprobe.md` and `openspec/notes/sr-data-flow.md` for the ownership lease model, the index, and attribution on ingest.
- [ ] 9.2 Add an operator runbook under `docs/` for shard placement, budgets, warming, and reading the attribution diagnostics.
