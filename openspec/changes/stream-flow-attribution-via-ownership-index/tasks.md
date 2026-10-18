## 0. Measure and spike (gate before build work)
- [ ] 0.1 On the lab, split current observation tuples into accepted (inbound, covered by a listener lease) and outbound (one lease each), and record active local keys per host. Project the per-host ownership event rate under Decision 1. Gate: median <= 5 events/s per host; otherwise revisit renewal period and close coalescing before 1.x.
- [ ] 0.2 Spike the shard store: ETS with packed binary keys and interned owners, at 2.5M keys per shard. Measure the distribution of history depth per key under the 15-minute horizon, bytes per key (including that history), batched lookup rate, and apply rate; size the default per-key history cap from the results. Gate: <= 200 bytes per key; otherwise move the store into a Rust NIF behind the same interface.
- [ ] 0.3 Measure replay time of 2 hours (the default stream `max_age`) of synthetic ownership events for one shard (2.5M keys). Gate: ready <= 2 minutes.
- [ ] 0.4 On the lab, measure distinct full connection-summary keys per host per minute and how often busy hosts reach the cap, and confirm the default per-agent summary cap (2,000 rows per interval) and the summary volume estimate in design.md Decision 9.
- [ ] 0.5 Record the results in this change's design.md, rounded, with no live hostnames, addresses or cluster names.

## 1. Netprobe: ownership leases
- [ ] 1.1 Extend `proto/agent/netprobe/v1/netprobe.proto`: `lease_op`, `first_seen_unix_nano`, `last_seen_unix_nano`, `ttl_seconds`, `closed` on `FlowAttributionEvent`; `AddressLease` and `snapshot_complete` on `FlowAttributionEventBatch`. Regenerate Go, Rust and Elixir bindings.
- [ ] 1.2 Key leases on the local endpoint in `rust/netprobe/src/attribution.rs`. Accepted sockets with the listener's owner emit nothing; a differing owner emits an exact peer entry keyed on the full 5-tuple, including the local port. Track covered accepted sockets per listener and promote the still-open ones to exact peer entries, ahead of the listener's `CLOSE` or owner-changing `OPEN`.
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
- [ ] 2.4 Create the `flow_ownership` stream (`flows.ownership.<bucket>`, 256 concrete leaves, `max_age` 2 hours, `discard: new`) with flow-owned limits. Assert no subject overlap with the `flows` stream, and refuse to start a shard when `max_age` is below lease TTL plus the larger of renewal period and history horizon plus margin.
- [ ] 2.5 Helm: NATS permissions for core publish and EventWriter subscribe on `flows.ownership.*`, and stream sizing values.

## 3. Ownership index
- [ ] 3.1 Shard store: endpoint keys, exact (5-tuple) and relaxed peer keys, address presence, a time-bounded validity history with a per-key cap and counted in-horizon evictions, an interned owner table, and workload identity resolved per owner record from the CNPG cache.
- [ ] 3.2 Time-T lookup with skew tolerance and the deterministic owner-order tie-break with ambiguous counting; and count `late_conflict` when a lease overlaps another owner's on a key after the affected flows' late windows closed.
- [ ] 3.3 Expiry through a timer wheel; history horizon for closed and expired leases; `SNAPSHOT` closes the agent's omitted leases at the snapshot time without deleting them.
- [ ] 3.4 Entry and byte budgets per shard, with ordered refusal and counters.
- [ ] 3.5 Shard ownership and placement on top of the existing lease and coordinator machinery: active owner, optional warm standby, bucket-range rebalancing; single-node and small installs place every shard on one node.
- [ ] 3.6 Rebuild by replay, restoring every lease within its TTL and every closed lease inside the horizon; `index_warming` until caught up.
- [ ] 3.7 Batched lookup API (one call per shard per flow batch): a local call when co-located, a distributed call otherwise.
- [ ] 3.8 Tests per scenario of *Endpoint Ownership Index Is Keyed Sharded And Bounded*.

## 4. Attribution on ingest
- [ ] 4.1 Allow the EventWriter flow pipeline (and the index shards) to run on every flow-tier node against the shared durable pull consumer. The rest of EventWriter stays coordinator-only.
- [ ] 4.2 Public endpoint map cache from `public_endpoints_current`, refreshed on change.
- [ ] 4.3 Attribution step in `Processors.Flows`: keys for both sides on their original endpoints plus VIP backend keys in the same batch (backend candidates only below the original's ranks 0-2), batched lookups, the precedence table, the cross-side tie-break, and a single write with `attributed_flow` and owner columns. Keep agent-provided attribution for the side the agent owns.
- [ ] 4.4 Monitored-side classification (address presence, or a VIP side with a monitored mapped backend, whose backend keys join hold, enrollment and home-shard placement). Hold buffer with item and byte caps, deadline below `ack_wait`, shard notification on `OPEN`, and no hold for unmonitored flows.
- [ ] 4.5 Late decision per home shard: enroll every flow with a monitored side (never agent-attributed flows) for the late window (default 5 minutes), finalizing early only under budget degradation; a watch set covering every key the flow could be attributed through (per side the endpoint, exact peer and relaxed peer keys, plus the same keys for every VIP backend), registered on each key's owning shard whether or not a candidate exists, with notifications routed to the home shard and watches living as long as the state; subscribe-with-snapshot registration (recompute on each acknowledgement) a single cutoff at window end where the last computed decision is final, cleanup-only unregistration after it, `decision_closed_unreconciled` for registrations unacknowledged at the cutoff, and `late_conflict` for notifications after it; on every candidate-set change of a watched key (OPEN/RENEW coverage, delayed CLOSE or SNAPSHOT shrink, horizon expiry, cap eviction, owner enrichment of a covering lease), publishing owner-context changes of the winner too, recompute the decision from the full candidate set (winner by `(rank, side, owner order)`, ambiguity evidence, full-tuple ties leave the side ambiguous) and publish whenever it differs from the last published decision, including evidence-only updates; versions fetched in batches; per-shard decision-state budget (<= 128 bytes per state and <= 24 bytes per watched key, default 6 GB at 16 shards) whose binding finalizes the oldest states early, sets `attribution_finalized_early` on their rows and counts `decision_finalized_early` per shard; `late_conflict` for claims and shrinks after window close.
- [ ] 4.6 Add `attribution_decision_seq` and `attribution_finalized_early` to `ocsf_network_activity` (sequence 0 on ingest), and make `FlowAttributionUpdates` apply an update only when its per-flow decision sequence is greater than the stored one (StarRocks conditional partial update); updates also carry precedence and ambiguity evidence for the row.
- [ ] 4.7 Tests per scenario of *Flows Are Attributed On Ingest By Key Lookup*, *Late Binding Is Bounded And Never Rescans Flows*, *Agent-Local Attribution Takes Precedence* and the modified *Correlation Is Protocol-Aware And Exact-First*.

## 5. Lease history and connection summaries
- [ ] 5.1 StarRocks DDL for `flow_ownership_leases` (Duplicate Key, daily partitions) in `elixir/serviceradar_core/priv/starrocks/`.
- [ ] 5.2 EventWriter processor that appends one row per ownership event; map the `attribution` retention dataset to the new table.
- [ ] 5.3 Netprobe producer: per-interval connection summaries keyed per Decision 9 (full keys including ephemeral ports, inbound and outbound), optional byte and packet counters, provenance, and the strict per-agent cap N (no aggregation below it; staged `peer_ip`, `service`, then per-direction `overflow` rows so at most N rows per interval) with merged-row counters by level and an overflow-interval counter. Add `ConnectionSummary` to `FlowAttributionEventBatch`.
- [ ] 5.4 Core ingest: carry summaries through the `flow-attribution` lane and publish them on `flows.connections.summary` in a dedicated `flow_connections` stream (short `max_age`), with NATS permissions and no subject overlap with `flows` or `flow_ownership`.
- [ ] 5.5 StarRocks DDL for `host_connection_summaries` (Duplicate Key, daily partitions), an EventWriter processor that appends them, and the `attribution` retention mapping.
- [ ] 5.6 Tests per scenario of *Hosts Report Per-Process Connection Summaries As Evidence*.

## 6. Health
- [ ] 6.1 Index and enrichment metrics on the JetStream metrics pipeline with bounded labels.
- [ ] 6.2 Per-interval diagnostics (`attributed`, `held`, `late_stamped`, `unmonitored`, `no_owner`, `ambiguous`, `index_warming`, `error`, `no_producer`, `no_flows`) replacing the per-pass outcomes; update the attribution health surface.

## 7. Capacity verification
- [ ] 7.1 Synthetic load harness using only invented data from documentation ranges (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24, 2001:db8::/32): simulated agents, ownership events, and flows.
- [ ] 7.2 Throughput run: >= 1M flows/s at the attribution stage, and >= 1.6x when flow-tier nodes are doubled, up to the warehouse write limit.
- [ ] 7.3 Ownership ingest run: 20k simulated agents for 1 hour; zero acknowledged loss; lag p99 <= 5 s.
- [ ] 7.4 Memory run: 40M active keys at <= 200 bytes per key, with every shard within budget; rebuild of a 2.5M-key shard <= 2 minutes.
- [ ] 7.5 Latency run: p99 added latency <= 250 ms per batch; holds within the window; late decision updates within 60 s; decision state within 128 bytes per enrolled flow and each shard within its budget across a full window.
- [ ] 7.6 Connection summary run: 20k simulated agents at the per-agent cap for 1 hour; zero acknowledged loss; every over-budget interval merged and counted; no agent emits more than its cap, including agents with more processes than the cap.

## 8. Cutover and removal (same release as 1-6)
- [ ] 8.1 Delete `FlowAttribution.Correlator`, `FlowAttribution.Correlation`, `PassMetrics`, the correlator kill switch and its supervisor wiring.
- [ ] 8.2 Delete `FlowAttribution.Observations`, the `FlowAttributionObservations` processor, `flows.attribution.observations` from the `flows` stream, EventWriter config and NATS permissions, and the StarRocks DDL for `flow_process_attribution_observations` (add a drop statement).
- [ ] 8.3 Remove the netprobe heartbeat and resend configuration (`DEFAULT_FLOW_ATTRIBUTION_RESEND_INTERVAL_S`, `FLOW_ATTRIBUTION_RAW_HEARTBEAT_INTERVAL`).
- [ ] 8.4 Search the workspace for every removed module, subject and table name (including tests, Helm, docs and `openspec/notes/`), and leave no dangling reference.
- [ ] 8.5 Post-rollout verification on the lab per the modified *Post-Rollout Verification Proves The Committed Artifact Chain*, gating on rows written after the rollout completed.

## 9. Documentation
- [ ] 9.1 Update `docs/docs/netprobe.md` and `openspec/notes/sr-data-flow.md` for the ownership lease model, the index, and attribution on ingest.
- [ ] 9.2 Add an operator runbook under `docs/` for shard placement, budgets, warming, and reading the attribution diagnostics.
