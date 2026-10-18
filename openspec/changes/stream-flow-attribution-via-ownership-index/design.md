## Context

Today (after `move-flow-attribution-to-starrocks`):

```
netprobe (eBPF ring + per-host cache, 300 s heartbeat re-emit, closes never emitted)
  -> agent push loop (FlowAttributionEventBatch, retained delivery)
  -> gateway -> core StatusHandler -> bounded flow-attribution admission lane
  -> JetStream flows.attribution.observations
  -> EventWriter FlowAttributionObservations
  -> StarRocks flow_process_attribution_observations (Duplicate Key, daily partitions, 30 d)

flow-collector -> JetStream flows.raw.* -> EventWriter Flows -> StarRocks ocsf_network_activity

Correlator (coordinator-only singleton, every 120 s):
  one StarRocks statement: <= 5,000 newest unattributed flows (last 15 min)
    x observations (last 30 min) x agent node IPs x public endpoint backends
  ranked: exact 5-tuple / ICMP (0), listener or relaxed UDP (1), node SNAT (2),
          public VIP by exposure class (3 + rank)
  -> workload identity from CNPG for winners -> events.flow.attribution
  -> EventWriter FlowAttributionUpdates -> partial PK update of ocsf_network_activity
```

Rounded figures from an 8-agent lab deployment:

| Quantity | Value |
| --- | --- |
| Observation rows per day | ~17.5M (~2.2M per agent, ~25 rows/s per host) |
| Distinct socket tuples per day | ~7.7M |
| Rows from one busy listener in 30 min | ~900 |
| Linear extrapolation to 20k agents | ~500k rows/s, ~44B rows/day |
| Correlator ceiling | 5,000 flows / 120 s = ~42 flows/s |
| Target flow rate (8k-20k exporters at ~50 flows/s) | 400k-1M flows/s |
| Observation re-scans per row | ~15 (30 min window / 2 min cadence) |
| Observation rows per pass at 20k agents | hundreds of millions (~900M) |
| Memory limit exceeded by the flows x observations join | ~8.7 GB per compute node |

Three structural facts drive the design:

1. **The producer emits sightings.** Netprobe already sees socket lifecycle events (connect,
   accept, state changes, close) but publishes cache refreshes: a re-emit on every fingerprint
   change, a 300 s heartbeat (`FLOW_ATTRIBUTION_RAW_HEARTBEAT_INTERVAL`) so central joins stay
   inside the 15-minute skew, an optional full resend, and no close. An accepted connection is
   keyed by its full 5-tuple, so a busy listener yields one row per client connection plus
   heartbeats.
2. **The consumer is a periodic global join.** Throughput is fixed by `LIMIT / interval`, and
   cost grows with flows x observations. The interim branch
   `fix/flow-attribution-correlator-memory` (unmerged) bounds the memory of that join by
   resolving the VIP backend first and picking winners with a streaming `min_by`. It cannot
   lift the ceiling.
3. **Stamping is a second write.** Flows are written unattributed, then rewritten by a partial
   primary-key update.

The question being answered is a key lookup: `(partition, proto, ip, port)` at time T -> owner.

## Goals / Non-Goals

- Goals:
  - Attribution cost is O(flows) with a constant number of key lookups per flow. No periodic
    global join, no re-scan of stored flows.
  - Producer volume is proportional to ownership changes, not to time or connection count on a
    listener.
  - Throughput scales horizontally: at least 1M flows/s attributed across consumers.
  - Ownership ingest from 20k agents. Index memory bounded per shard and proportional to active
    sockets.
  - Flows are written once, already attributed. The only write-back is a bounded late stamp.
  - Existing match semantics and precedence are kept, along with the flow attribution columns
    that UI and SRQL read.
  - Everything flows through JetStream; StarRocks remains the only flow store; no CNPG
    telemetry writer or reader.
- Non-Goals:
  - NAT beyond node SNAT and Kubernetes public endpoints (edge firewalls, CGNAT, cloud NAT
    gateways).
  - Attributing both endpoints of a flow into separate columns (see Open Questions).
  - Changing how the UI or SRQL read attributed flows.
  - Reviving central-to-agent flow replay (`flow.host-slice.*`), which stays retired.
  - A CNPG fallback, dual-write, or backfill.
  - Fixing StarRocks flow write throughput. This change requires that attribution never be the
    bottleneck. Warehouse ingest capacity is a separate constraint.

## Decisions

### 1. Agents emit ownership leases, not sightings

Netprobe publishes **socket ownership leases** keyed on the local endpoint
`(proto, local_ip, local_port)` plus the owner record. Each lease event carries an operation:

- `OPEN`: a new key, or a new owner for a known key (port reuse). Sent when the socket
  first resolves to an owner.
- `RENEW`: the lease is still active. Sent once per renewal period (default 30 minutes, jittered
  per agent), not every 300 s.
- `CLOSE`: the kernel reported the socket closed. An `OPEN` and `CLOSE` that fall inside one
  agent batch window (default 5 s) are coalesced into one `OPEN` with `last_seen` and a closed
  flag, so a short-lived connection costs one event.
- `SNAPSHOT`: the full set of active leases, sent on netprobe start and after an agent
  reconnects. The index adopts the snapshot as that agent's active set and closes, at the
  snapshot's time, any of the agent's leases the snapshot omits.

Each event carries `first_seen`, `last_seen`, and a `ttl` (default 2 x renewal period). It
also carries the owner: `pid`, `tgid`, `uid`, `comm`, `redacted_cmdline` (already redacted and
capped at 256 bytes by netprobe), `container_id`, and `workload_identity` when known. A
fingerprint change to the owner, such as late cmdline enrichment from the procfs cold path, is
an `OPEN` with the same key and `first_seen`.

Keying on the local endpoint is what makes this cheap:

- **Listeners are one lease.** An accepted connection is covered by its listener's lease and
  emits nothing, unless the accepted socket's owner differs from the listener's (worker
  hand-off, `SO_REUSEPORT` groups with different tgids). In that case the agent emits an
  exact peer entry keyed on the connection's full 5-tuple (Decision 2).
- **Wildcard listeners are expanded by the agent** into one lease per local address. The agent
  knows its own addresses, so the central index never has to guess which host a `0.0.0.0`
  belongs to. The agent also publishes **address leases** (its local addresses, renewed like
  socket leases, closed on removal), and re-expands wildcard leases when its addresses change.
- **Unconnected UDP sockets are one lease** however many peers they talk to.
- **Outbound connections** are one event per new local ephemeral key, which bounds the volume
  from above.

Expected volume: a host emits `(new outbound keys/s) + (active leases / renewal period) +
(address changes)`. For a host with 2,000 active keys and a 30-minute renewal that is ~1.1
renewals/s plus its outbound connection rate. The lab figures do not separate inbound
(accepted, now free) from outbound tuples. **Phase 0 measures that split on the lab before any
build work.** The target is a handful of events per host per second at the median, with the
per-host outbound connection rate as the stated upper bound.

A per-agent budget (events/s and burst) is enforced in netprobe. Over budget, netprobe first
drops renewals of leases that are already known, then new outbound keys, and counts the drops
by reason. Listener and address leases are never shed. A shed renewal does not change what a
lease's validity is: the lease stays valid until the `last_seen + ttl` of its last delivered
event, on a running shard and after a rebuild alike (Decision 2).

- Alternatives considered:
  - *Keep sightings, coalesce centrally.* This still ships and stores ~25 rows/s per host, and
    the central side still has to deduplicate them. Rejected.
  - *Pure open/close with no renewal.* The smallest stream, but a shard that rebuilds from a
    time-bounded stream loses every lease older than the stream's `max_age`, and a lost close
    leaves a lease alive forever. Renewal plus TTL makes rebuild complete and makes lost
    events self-healing. Rejected.
  - *Key on the full 5-tuple.* Exact for every connection, but it keeps one key per accepted
    connection, which is the source of most listener volume. Rejected. Exact server-side
    entries keep the full 5-tuple, and are emitted only when the owner differs (Decision 2).
  - *Periodic full snapshot only.* Simple, but volume is proportional to active sockets times
    snapshot frequency, and freshness is bounded by the snapshot period. Rejected except on
    start and reconnect.

Wire format: extend `FlowAttributionEvent` with `lease_op`, `first_seen_unix_nano`,
`last_seen_unix_nano`, `ttl_seconds`, and `closed`, and add `AddressLease` and
`snapshot_complete` to `FlowAttributionEventBatch`. The `flow-attribution` delivery source,
retained delivery, and gateway path are unchanged. During rollout, an event without `lease_op`
(an old netprobe) is applied as an `OPEN` with a 10-minute TTL. This is only a decoding default
for mixed versions; nothing is dual-written.

### 2. A central endpoint ownership index, sharded by key

**Key families** (every key includes `partition`, and addresses are normalized: lowercased,
with `::ffff:` stripped):

- **Endpoint key** `E = (partition, proto, ip, port)` -> lease. Each lease has a kind:
  `connected` (records its remote endpoint) or `bound` (listener, expanded wildcard, or
  unconnected UDP).
- **Exact peer key** `X = (partition, proto, ip, port, remote_ip, remote_port)` -> lease. The
  full 5-tuple of an accepted connection whose owner differs from the listener's. Keeping the
  local port means two connections from one client to two local ports of one address resolve
  to their own owners; the listener's `bound` lease remains the fallback for that endpoint.
- **Relaxed peer key** `R = (partition, proto, ip, remote_ip, remote_port)` -> lease. Used only
  for the families that are matched without the local port: ICMP (ports zero), relaxed UDP,
  and node SNAT. For node SNAT, the publisher derives a relaxed peer entry
  `(partition, proto, node_ip, remote_ip, remote_port)` for each outbound `connected` lease
  whose local address is not one of the agent's node addresses. The node IP comes from the
  agent's registered address, as the correlator uses today.
- **Address presence** `A = (partition, ip)`: a reference count of active leases and address
  leases on an address. It answers "is this a monitored address" (Decision 4).

**Value**: a time-bounded validity history per key. Each entry is one lease,
`[first_seen, closed_at or last_seen + ttl)`, pointing at an interned **owner record**. Owner
records (`agent_id, pid, uid, comm, redacted_cmdline, container_id, workload_identity`) are
stored once and referenced by id, because many keys share one owner. Workload identity is
resolved once per owner record at insert, from the CNPG `workload_identity_current` cache by
`(partition, agent_id, container_id)`. Identity carried on the event wins, as today. Closed
and expired leases are kept until their interval ended more than the history horizon ago
(default 15 minutes, the current skew), so a flow exported after its socket closed still
resolves at its own time T. History is bounded by time, not by a fixed slot count: every lease
whose interval ended inside the horizon stays resolvable, however many owners a reused key had.
A per-key cap (default 32 entries) sized from the horizon and the shard's byte budget protects
memory against a pathological key. On overflow the shard first drops entries whose interval
ended beyond the horizon, then the oldest entry inside the horizon, and it counts each
eviction inside the horizon (`history_evicted`), so a lost interval is visible rather than
silently unmatched.

**Time-T lookup**: pick the lease whose interval contains T within a skew tolerance (default
5 s). If several do (two agents claim one key with overlapping validity), pick
deterministically: container id first, then the most recent `first_seen`, then `agent_id`,
then `pid`. That is the current tie-break. Count the result as `ambiguous`.

**Sharding**: keys hash on `(partition, ip)` into 256 fixed **buckets**. E, X and R (hashed on
their first ip), and A for one address therefore live in one bucket, so one lookup answers
owner, peer, and presence together. Buckets are grouped into N **shards** (default 16). Each shard is
owned by one active node, with an optional warm standby, through the existing
coordinator/lease machinery. Because the bucket count is fixed, the publisher never changes
when shards move. Rebalancing moves bucket ranges. A single-node or small installation uses the
same layout and simply places every shard on its one flow node; there is no separate replicated
mode.

**Memory bound**: each shard has an entry budget and a byte budget. Expired leases are evicted
in expiry order (a timer wheel, not a scan). When the budget is still exceeded, new `RENEW`
and `OPEN` entries for outbound `connected` leases are refused before `bound` leases, and every
refusal is counted. A shard never grows past its budget.

**Size**: the index is sized by active sockets, not by observations. Assuming 1-2k active keys
per host, 20k hosts is 20-40M keys. A key costs its packed key and table overhead plus one
fixed-size history entry (two timestamps, an owner id and flags, about 32 bytes) per interval
it holds inside the horizon, plus its share of interned owners. Most keys hold one interval;
reused outbound keys hold a few. At a target of at most 200 bytes per active key on average,
including the history each key holds and its owner share, that is 4-8 GB across all shards.
The per-key cap bounds the worst case, not the average. Phase 0 measures active keys per host,
the distribution of history depth per key under the 15-minute horizon, and the bytes per key
of the chosen store.

**Store**: per-shard ETS tables with packed binary keys (a 16-byte address, 2-byte port, 1-byte
proto, and an integer partition id) and a separate owner table. If the Phase 0 spike measures
more than 200 bytes per entry, or cannot reach the lookup rate, the store moves into a Rust NIF
behind the same shard interface. The project already ships Rust NIFs.

**Where the index lives (recommended):** in-memory shards hosted by the EventWriter flow tier
and fed from JetStream. Each shard consumes its bucket subjects from a dedicated
`flow_ownership` stream (`flows.ownership.<bucket>`, 256 concrete leaves; it does not overlap
the `flows` stream's concrete `flows.raw.*` leaves). On restart a shard replays its subjects.
The rebuild contract is that replay restores every lease still within its TTL and every
closed or expired lease still inside the history horizon. A shard only ever grants validity
from an event it has applied, up to that event's `last_seen + ttl`, and keeps the interval for
the horizon after it ends. Stream `max_age` must therefore be at least the lease TTL plus the
larger of the renewal period and the history horizon, plus a safety margin for jitter and
publish lag (default 2 hours: 60-minute TTL, 30-minute renewal, 30-minute margin), and
EventWriter refuses to start a shard against a stream configured below that bound. The stream
uses `discard: new`, so a stream at its byte limit refuses publishes (which retained delivery
retries) instead of dropping old events that a replay needs. Renewal shedding and snapshots stay
inside this contract: a shed renewal only lets a lease expire at the validity its last event
already granted, and a `SNAPSHOT` closes the agent's omitted leases at the snapshot's time
instead of deleting them, so neither shortens an interval a running shard holds. Both are
events in the stream, so a replay reproduces the same result. While a shard
is warming, its lookups return `index_warming` and the affected flows enter the late-stamp set
(Decision 4). A warm standby makes failover immediate.

- Alternatives considered:
  - *NATS KV bucket keyed by endpoint.* Durable last-value-per-key for free, and history up to
    64 revisions. But a lookup is a network round trip per key: 2M gets/s at 1M flows/s, with
    no batched multi-key get on the lookup path. Tens of millions of keys at R3 with ~100k
    writes/s is heavy on NATS storage. A watcher-fed local cache would rebuild this design with
    one more layer. Rejected for the lookup path; it could hold periodic shard snapshots later
    if replay time becomes a problem.
  - *StarRocks primary-key table (endpoint -> owner).* Point lookups are not what an OLAP engine
    is built for: tens of milliseconds per query and limited QPS. An upsert per ownership event
    reintroduces the delete-vector and compaction churn that `move-flow-attribution-to-starrocks`
    rejected for observations. Rejected.
  - *CNPG table.* Forbidden for telemetry when StarRocks is in play, and it is the exact churn
    pattern (17 GB of bloat) the archived change removed. Rejected.
  - *Enrich in the flow-collector (Rust) before publish.* Closest to the source and fast. But
    the collector is a stream-ownership singleton today, every collector would need the full
    index, and a slow index would back-pressure the UDP receive path and drop packets.
    Rejected for now; revisit only if the EventWriter flow tier cannot meet per-node
    throughput.
  - *Shard flow consumers by endpoint hash so lookups are always local.* A flow has two
    endpoints that hash to different shards, so consistent sharding co-locates at most one of
    the two lookups, and the other still crosses nodes. Rejected (see Decision 3).
  - *Full index replica in every flow consumer.* Every lookup is local and nothing crosses
    nodes, but memory is index size x replicas, and every replica applies the full ownership
    stream. It adds a second placement and consumption mode for no gain over placing all shards
    on one node in a small install. Rejected.

### 3. Flows are attributed on ingest in the EventWriter flow path

The EventWriter `Flows` processor gains an attribution step between decode/enrichment and the
single StarRocks write:

1. For each flow in the batch, build the lookup keys for both sides from the endpoints the
   exporter reported. A side that matches the cached **public VIP map** (from CNPG
   `public_endpoints_current`, refreshed on change, keyed by `(proto, vip_ip, vip_port)`) also
   gets keys for its backend endpoints. The original endpoint is always looked up: backend
   keys add public-endpoint candidates, they never replace the original's candidates. Both
   key sets go into the same batched lookup. The VIP is a lookup in front of the index, not a
   join branch.
2. Group the keys by bucket, then by shard owner, and issue **one batched lookup per shard per
   flow batch**. When the shard is local this is a function call; otherwise it is one
   distributed call over the existing ERTS cluster.
3. Apply the precedence per side and then across sides, and write the row once with
   `event_type = attributed_flow`, the owner columns, and `public_endpoint` where applicable.

Precedence keeps the current ranks and their metric names:

| Rank | Strategy | Lookup |
| --- | --- | --- |
| 0 | exact | `E(side)` `connected` lease whose remote equals the other side; `X(side.ip, side.port, other.ip, other.port)` exact peer entry; ICMP `R(side.ip, other.ip, 0)` |
| 1 | listener / relaxed UDP | `E(side)` `bound` lease; UDP `R(side.ip, other.ip, other.port)` |
| 2 | node SNAT | `R(node_ip = side.ip, other.ip, other.port)` |
| 3 + exposure | public endpoint | VIP -> backend `E`, `X` or `R` (Gateway 0, LoadBalancer/ExternalIP 1, other 2) |

Ranks 0-2 are looked up on the original endpoint, so a VIP side's backend candidates win only
when the original endpoint has no candidate at those ranks; in particular an exact owner of the
original endpoint is never displaced by a backend mapping. Across sides, the lower rank wins. On a tie the source side wins: it is the sender of the bytes
the record counts, so the two directional records of one conversation each attribute their own
sender. The row keeps the existing single-owner columns.

Throughput scales by adding flow-tier nodes. The `Flows` processor must run on every
flow-tier node against the shared durable pull consumer, so JetStream distributes the work.
Today the whole EventWriter supervisor is a coordinator-only singleton. This change moves the
flow pipeline (and the index shards) out from under that restriction, and leaves the rest of
EventWriter as it is. Index shards and flow consumers scale independently: consumers by flow
rate, shards by index size.

There is no write-back on this path and no periodic global join. The cost per flow is a
constant: at most a handful of hash lookups, batched.

- Alternatives considered:
  - *Keep the correlator and make it key-based.* Still periodic, still bounded by
    `LIMIT / interval`, and it still rewrites flows. Rejected.
  - *A separate attribution stage that consumes flows, attributes them, and republishes.* This
    doubles JetStream flow traffic (1M -> 2M msg/s) for no gain over attributing inside the
    writer. Rejected.

### 4. Late binding is bounded: hold, then late stamp

A flow can arrive before its ownership event, because agent batches lag a few seconds behind
the kernel event.

- **Hold**: if a side's address is a monitored address (`A` present) but no lease matches,
  the flow is held in a per-consumer buffer for up to the hold window (default 5 s, maximum
  30 s, and always below the consumer `ack_wait`). The shard notifies waiting consumers when a
  matching `OPEN` arrives, and otherwise the flow is retried once at the deadline. A flow with
  no monitored address on either side is never held: it is written immediately with outcome
  `unmonitored`. The hold buffer has an item cap and a byte cap. On overflow the flow is
  written immediately and goes to the late-stamp set.
- **Late stamp**: a flow written without an owner while one of its sides is a monitored
  address is recorded once, in the late-stamp set of its **home shard** (the shard of its
  source side's bucket, or of the destination's when only the destination is monitored), as
  `(flow id, flow time, both sides' keys, current rank)`. Each other monitored side's shard
  keeps only a watch `(key, flow id, home shard)`. Entries and watches live for the late-stamp
  window (default 10 minutes) under an entry cap, and the oldest is evicted with a counter.
  When a lease arrives that covers a recorded flow's time, the shard that applied it notifies
  the home shard, which re-runs the lookup for both sides under the same precedence as on
  ingest (including the VIP rule) and makes one decision for the flow. It publishes a
  versioned update on `events.flow.attribution` only when the winner ranks strictly better than
  the flow's current rank, and keeps the entry until the flow reaches rank 0 or the window ends.
  Only the home shard publishes for a flow, so each later version carries a better candidate
  than the one before, and the version order the existing `FlowAttributionUpdates` processor
  applies (partial primary-key update, highest version wins) agrees with the precedence. No
  two shards ever write the same flow independently. Versions come from
  `flow_attribution_update_version` in batches, and only late stamps consume them.
- **Never a full re-scan**: nothing reads stored flows back to find unattributed ones. The
  late-stamp set is the only memory of unmatched flows, and it is bounded.

- Alternatives considered:
  - *No hold, only late stamp.* Simpler, but every flow that races its ownership event becomes a
    write plus a rewrite. A short hold absorbs the common race without a second write.
  - *A long hold (minutes).* This ties up unacknowledged JetStream messages and memory in
    proportion to flow rate. Rejected.
  - *A periodic sweep of recent unattributed flows.* This is the current correlator again, with
    its ceiling. Rejected.

### 5. Agent-local attribution stays primary for flows the agent observes

When an agent produces the flow record itself (netprobe's local `ExternalFlowMatcher` path,
which emits `AttributedFlowMessage` with the attribution already attached), the flow arrives
attributed, and the `Flows` processor keeps that attribution: it does not look up the side the
agent owns. The agent's own cache is fresher than any central index. Today no production
producer feeds external flow records to netprobe, and `flow.host-slice.*` routing is retired.
This change preserves the precedence for when such a producer exists and does not revive the
replay. Flows from routers, switches and other exporters use the index.

### 6. Ownership history for incident response

The archived change kept observations for 30 days so operators could ask which process talked
to an address in the past. That question is answered by a much smaller dataset: an
EventWriter processor consumes `flows.ownership.*` and appends one row per ownership event
(`OPEN`, `RENEW`, `CLOSE`, `SNAPSHOT` entries) to a StarRocks Duplicate Key table,
`flow_ownership_leases`, partitioned by day. It is governed by the existing `attribution`
retention dataset (default 30 days, floor 1 day). Expected volume is the ownership event rate:
a few events per host per second instead of ~25 sightings. Attributed flow rows also carry
their owner, which answers the question for every sampled flow.

### 7. Ingest scaling at the edge-to-core boundary

Ownership batches keep the `flow-attribution` source, retained delivery, and the bounded
admission lane. Two parts of the lane's contract change:

- **Completion is the JetStream acknowledgement.** The lane already publishes rather than
  writing a database, so it replies after every message of the unit is acknowledged.
- **Concurrency is configurable.** With a single worker, a fleet of 20k agents, each sending a
  batch every 5-30 s, is 700-4,000 batches/s through one publisher. The default stays one
  worker and every other bound is unchanged, but deployments can raise the worker count.
  Publishing is idempotent at the index (a repeated lease event leaves the index unchanged),
  so concurrent workers are safe.

The publisher derives bucket subjects and node-SNAT peer entries, splits messages by bucket,
and enforces the existing per-message row and byte caps.

### 8. Health and diagnostics

Metrics travel on the JetStream metrics pipeline with bounded labels (no agent id, IP, port,
pid, cmdline or partition labels):

- Index: entries and bytes per shard, budget refusals, evictions (history evictions inside
  the horizon separately), ownership consumer lag,
  shard state (`warming`, `ready`, `standby`), rebuild duration, and ambiguous count.
- Enrichment: flows by outcome (`attributed` by strategy, `held`, `late_stamped`,
  `unmonitored`, `no_owner`, `ambiguous`, `index_warming`, `error`), hold buffer depth and
  overflow, late-stamp set size, evictions and applied stamps, lookup latency per batch, and
  agent budget drops by reason (reported by netprobe).

Per-interval diagnostics replace the per-pass ones: `no_producer` (no ownership events in the
interval), `no_flows` (no flows reached the processor), and `unmonitored` (the successor of
`no_topology_overlap`).

## Capacity targets

These are requirements (see the spec delta), verified by a synthetic load harness in Phase 7.
Load is generated from invented data in 192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24 and
2001:db8::/32.

| Target | Value |
| --- | --- |
| Flows attributed, aggregate | >= 1M flows/s across horizontally scaled flow-tier nodes, measured on the attribution stage |
| Scale-out efficiency | doubling flow-tier nodes yields >= 1.6x attributed throughput until the warehouse write limit |
| Ownership ingest | 20k simulated agents at the Phase 0 per-host rate (at least 5 events/s each, >= 100k events/s aggregate) for 1 hour, no unacknowledged loss, ownership lag p99 <= 5 s |
| Index memory | <= 200 bytes per active key on average; each shard stays within its configured budget |
| Added latency | p99 <= 250 ms per flow batch for flows whose owner is present |
| Hold | flows written within the hold window (default 5 s, maximum 30 s) |
| Late stamp | applied within 60 s of the late ownership event |
| Rebuild | a shard of 2.5M keys is ready within 2 minutes of start |

## Risks / Trade-offs

- **Ownership volume is higher than expected** (outbound-heavy hosts such as proxies and
  crawlers). Mitigation: the Phase 0 measurement gates the build; per-agent budgets with
  explicit shedding; renewal period is configurable.
- **Memory blowup in ETS.** Mitigation: the Phase 0 spike, per-shard budgets with refusal
  accounting, and a Rust NIF store behind the same interface.
- **Cross-node lookup latency** when shards are spread across nodes. Mitigation: one batched
  call per shard per flow batch; small installs place every shard on their one flow node.
- **Clock skew** between exporters and agents. Mitigation: a skew tolerance on the time-T
  lookup and a history horizon equal to today's 15-minute skew; the tolerance is a setting.
- **Long active timeouts on exporters** can put a flow's time far from the socket's lifetime.
  Mitigation: the history horizon covers closed leases; open question below on which flow
  timestamp to use.
- **JetStream load** of the ownership stream at fleet scale (~100k events/s, R3). Mitigation: a
  dedicated stream with its own limits; owner records deduplicated within a message; a
  `max_age` no longer than the rebuild contract requires (default 2 hours).
- **Loss of attribution precision for accepted connections** whose worker pid differs from the
  listener's but whose difference the agent cannot see. Mitigation: exact peer entries are
  emitted whenever the accepted socket's tgid differs; the listener owner is otherwise the
  correct process group.
- **Moving the flow pipeline out of the coordinator singleton** touches EventWriter
  supervision. Mitigation: only the flow pipeline and the index move; other pipelines stay
  coordinator-only.

## Migration Plan

Straight switch in one release, following `move-flow-attribution-to-starrocks`: attribution
state is ephemeral, and only the team's own deployments run flow attribution.

1. Ship netprobe and agent lease emission, the ownership publisher and stream, the index, and
   on-ingest attribution together, with the correlator deleted in the same release.
2. While old netprobe versions roll forward, their events decode as `OPEN` with a 10-minute TTL
   (Decision 1). Their heartbeats keep those leases alive until the agent upgrades.
3. Drop `flow_process_attribution_observations` and remove `flows.attribution.observations`
   from the `flows` stream, the NATS permissions and the EventWriter config. Create
   `flow_ownership_leases` and the `flow_ownership` stream.
4. Run the post-rollout verification against the lab.

Rollback: redeploy the previous release together with the previous netprobe add-on version,
because the correlator needs sighting heartbeats. It works again once 30 minutes of new
observations have arrived. Flows written while this change was live remain attributed. The dropped
observation table is recreated by its DDL.

## Open Questions

- **Both endpoints**: should a flow whose two sides are both monitored store two owners
  (side-qualified columns) instead of one? This would change UI and SRQL readers; left as a
  follow-up.
- **Which flow timestamp** to look up with (start, end, or both) for exporters with long active
  timeouts, and whether the history horizon should follow the exporter's timeout.
- **History horizon and TTL defaults**: how long a closed lease must stay resolvable, and
  whether 15 minutes is enough at fleet scale.
- **NAT beyond node SNAT** (edge SNAT, CGNAT, cloud NAT gateways): out of scope. Is there a
  practical source of translation state to put in front of the index the way the VIP map is?
- **IPv6 privacy addresses**: temporary addresses rotate. Do address leases and wildcard
  re-expansion keep up, or should wildcard listeners match by prefix for privacy addresses?
- **Sampled flows**: sampling does not change the lookup. Should late-stamp and hold caps be
  sized by sampled or by estimated flow rate?
- **Overlapping address spaces within one partition** (for example, two clusters that reuse
  the same pod CIDR under one partition): today's tie-break picks one owner and counts it
  `ambiguous`. Should overlap be a configuration error instead?
- **Cmdline in the index**: keep the redacted cmdline in memory, or keep only a hash and resolve
  the text from `flow_ownership_leases` when a flow is written?
- **Lease history at fleet scale**: at 20k agents the history table is still on the order of
  billions of rows per day. Is the 30-day default still right, or should the lease history get
  its own retention dataset?
