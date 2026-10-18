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
  - Ownership volume is proportional to ownership changes, not to time or connection count on a
    listener. Peer evidence travels separately as bounded per-interval connection summaries
    (Decision 9).
  - Host-observed connection evidence (which process talked to which peer) is kept for
    host-only exposure queries and for matching network-observed flows, without NetFlow.
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
  emits no lease of its own (its peer is still counted in a connection summary, Decision 9),
  unless the accepted socket's owner differs from the listener's (worker
  hand-off, `SO_REUSEPORT` groups with different tgids). In that case the agent emits an
  exact peer entry keyed on the connection's full 5-tuple (Decision 2).
- **Accepted sockets are promoted when listener coverage ends.** Netprobe tracks the accepted
  sockets each listener lease covers. Before it emits a `CLOSE` for a listener lease, or an
  `OPEN` that gives the listener key a new owner, it emits an exact peer entry (`OPEN`, with
  the accepted socket's own `first_seen` and owner) for every covered accepted socket that is
  still open, in the same batch and ahead of the listener event. Each promoted entry then
  lives and closes like any other lease. A process that closes its listener during a graceful
  shutdown therefore keeps its in-flight connections attributed, and a process that later
  binds the same port does not inherit them, because exact entries outrank its listener
  lease.
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
deterministically by the **owner order**: container id first, then the most recent
`first_seen`, then `agent_id`, then `pid`. That is the current tie-break. It is a property of
the candidate leases, never of their arrival order, and it is the third component of
precedence (Decision 4), so the ingest path and the late path pick the same owner. Count the
result as `ambiguous`; the flow row's match evidence records it as ambiguous.

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
is warming, its lookups return `index_warming` and the affected flows are enrolled for a late decision
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

- **Monitored sides**: a flow side is monitored when its address has presence (`A`), or when
  it matches the public VIP map and any of its mapped backend addresses has presence. For a
  VIP side, the backend keys are the side's keys for hold, enrollment and home-shard
  placement, and join the watch set below, alongside its original keys, so a backend lease that arrives after the
  flow still attributes it under the same precedence (public-endpoint rank, below any
  original-endpoint candidate).
- **Hold**: if a side is monitored but no lease matches,
  the flow is held in a per-consumer buffer for up to the hold window (default 5 s, maximum
  30 s, and always below the consumer `ack_wait`). The shard notifies waiting consumers when a
  matching `OPEN` arrives, and otherwise the flow is retried once at the deadline. A flow with
  no monitored side is never held: it is written immediately with outcome
  `unmonitored`. The hold buffer has an item cap and a byte cap. On overflow the flow is
  written immediately and is enrolled for a late decision.
- **Late decision**: **precedence** is the full ordering tuple `(rank, side, owner order)`
  with the source side ahead of the destination, the same total order the ingest path applies
  (Decisions 2 and 3); an unattributed flow has the lowest precedence. One rule covers every
  arrival order: **for a flow whose decision state is retained for its full late window, the
  final decision is a function of the candidate set as it stands when the window closes,
  independent of the order in which lease events arrived.** Budget-forced early finalization
  (*Bound* below) is the one specified exception, and it is flagged on the flow.
  - *Enrollment*: every flow with a monitored side is enrolled when it is written, whether it
    was written without an owner or with an ingest winner. Nothing finalizes a decision early
    except the budget degradation below: an exact source-side winner is enrolled like any other, because a competing claimant can
    still arrive. A flow attributed by its agent (Decision 5) is not enrolled, so a late
    decision never replaces agent-local attribution. A flow with no monitored side can have
    no candidate and is not enrolled.
  - *State*: the flow is recorded once, in the **home shard** (the shard of its source side's
    bucket, or of the destination's when only the destination is monitored; for a monitored
    VIP side that is not an agent address, the shard of its first mapped backend), as a
    decision state `(flow id, flow time, both sides' keys, published decision)`.
  - *Watch set*: an enrolled flow watches **every key it could be attributed through**,
    whether or not a candidate exists for that key yet and whether or not that side is
    monitored. For each side `s` with other side `o`, that is the endpoint key
    `E(s.ip, s.port)` (connected, listener and expanded wildcard leases), the exact peer key
    `X(s.ip, s.port, o.ip, o.port)`, and the relaxed peer key `R(s.ip, o.ip, o.port)` (relaxed
    UDP and node SNAT; `R(s.ip, o.ip, 0)` for ICMP); for a side that matches the VIP map, the
    same three keys for every mapped backend endpoint as well. All keys of one side (or one
    backend) hash to one bucket, so registration sends one message per side or backend to the
    shard that owns that bucket, and that shard routes every notification back to the flow's
    home shard. Registration is **subscribe-with-snapshot**: the owning shard, in one step,
    records the watch and returns the key's candidate state at the flow time as of that
    moment, and the home shard recomputes the decision when each registration
    acknowledgement arrives. A lease applied before registration is therefore in the
    snapshot, and one applied after it produces a notification; neither can be missed.
    Watches live exactly as long as the decision state. The candidate set itself is not
    copied: it is the index's history for the flow's keys at the flow time, which the history
    horizon keeps for longer than the window.
  - *Decision*: any change to the candidate set of a key in the watch set during the window
    notifies the home shard: a lease that starts to cover the flow's time (`OPEN`, `RENEW`), a validity
    interval that shrinks so it no longer covers it (a delayed `CLOSE`, a `SNAPSHOT` that
    closes an omitted lease), a history entry removed by horizon expiry or the per-key cap, and
    an owner-attribute change to a lease that covers the flow's time (an enrichment `OPEN` with
    the same key and `first_seen` that adds the cmdline, container id or workload identity).
    The shard that applied the mutation notifies when coverage of the flow time changed or
    when the owner record of a covering lease changed. The home shard then recomputes the
    decision from the full candidate set of both sides (including the VIP rule): the winner by full precedence, plus the number
    of other owners that tie with it on `(rank, side)` as ambiguity evidence. Two distinct
    owners that tie on the full tuple cannot be separated, so the side is then `ambiguous` and
    carries no owner.
  - *Publication*: the home shard publishes an update on `events.flow.attribution` whenever the
    decision differs in any way from the one last published: a different winner, a lower
    winner after a candidate lost coverage, changed owner context for the same winning lease, a return to unattributed, a change between
    unambiguous and ambiguous, or new ambiguity evidence with the same winner (an
    evidence-only update). Each update carries the decision's precedence and ambiguity
    evidence, and a per-flow **decision sequence** that the home shard increments with every
    publication (the row written on ingest is sequence 0). Because the candidate set can
    shrink, precedence alone cannot order decisions: `FlowAttributionUpdates` applies an
    update as a partial primary-key update only when its decision sequence is greater than the
    row's stored `attribution_decision_seq` (a StarRocks conditional update on that column), so
    the row converges on the latest complete decision and an obsolete higher-precedence stamp
    cannot survive. Only the home shard publishes for a flow; no two shards ever write the
    same flow independently, so the sequence is a total order per flow.
  - *Close*: when the window ends (default 5 minutes) the home shard unregisters every watch
    with the same snapshot semantics: each owning shard, in one step, removes the watch and
    returns the key's current candidate state, so every mutation it accepted before that
    point is included. The home shard makes one final recompute once all unregistrations, and
    any registrations still outstanding, are acknowledged, publishes it if it differs, and
    drops the state; that decision is final. If acknowledgements have not arrived by the
    closing deadline (default 10 s after the window ends), the deadline wins: the home shard
    closes with the decision computed from what it has and counts the case
    (`decision_closed_unreconciled`). A claim or a validity shrink that arrives after the window
    does not re-open the flow; the shard counts it as `late_conflict`.
  - *Bound*: a decision state is at most 128 bytes (a 16-byte flow id, a 4-byte flow time, two
    packed endpoint keys of about 20 bytes each, the published decision, sequence and owner id,
    and table overhead). A watch registration is one index entry per watched key, at most
    24 bytes (key hash and flow reference); a flow without VIP sides registers six (three per
    side), and each VIP backend adds three. At 1M enrolled flows/s, the 5-minute window holds
    300M states: about 38 GB of states and about 43 GB of watch entries across all shards,
    about 81 GB in total (about 5.1 GB per shard at the default 16 shards). Each shard has a
    decision-state budget covering states and watches, by default 6 GB at 16 shards, sized so
    that early finalization does not occur at the stated targets; the window and the shard
    count are the sizing levers.
  - *Budget degradation*: if the budget binds anyway, the oldest states finalize early with
    their last decision. The home shard publishes one last update for each, setting the
    SRQL-visible flag `attribution_finalized_early` on the flow row, and counts every early
    finalization per shard (`decision_finalized_early`). The arrival-order guarantee covers
    only flows whose state was retained for the full window; a flagged flow is the documented
    exception.
  - Versions come from `flow_attribution_update_version` in batches, and only late decisions
    consume them.
- **Never a full re-scan**: nothing reads stored flows back to find unattributed or
  fallback-attributed ones. The decision states are the only memory of flows whose
  attribution can still change, and they are bounded.

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
  shard state (`warming`, `ready`, `standby`), rebuild duration, ambiguous count, and `late_conflict` (a claim overlapping another owner's lease on a key).
- Enrichment: flows by outcome (`attributed` by strategy, `held`, `late_stamped`,
  `unmonitored`, `no_owner`, `ambiguous`, `index_warming`, `error`), hold buffer depth and
  overflow, decision state count and bytes, early finalizations (`decision_finalized_early`), unreconciled closes (`decision_closed_unreconciled`), evictions, applied
  and evidence-only updates, lookup latency per batch, and
  agent budget drops by reason (reported by netprobe).
- Connection summaries: rows per interval, rows merged by the budget and the level they were
  merged to, intervals that reached the `overflow` level (reported by netprobe), and summary
  consumer lag.

Per-interval diagnostics replace the per-pass ones: `no_producer` (no ownership events in the
interval), `no_flows` (no flows reached the processor), and `unmonitored` (the successor of
`no_topology_overlap`).

### 9. Host-observed connection summaries (peer evidence)

Keying leases on the local endpoint collapses accepted connections into their listener's
lease, so the index alone cannot say who a process talked to. That peer evidence is needed for
host-only exposure queries in deployments without NetFlow, and for spotting a
network-observed connection that no host observed (#5745). Netprobe therefore emits
**connection summaries** alongside the leases. They are evidence, not a lookup key: the
ownership index never reads them, and attribution never depends on them.

- **Key**: `(agent_id, owner, local_ip, local_port, peer_ip, peer_port, proto, direction)`,
  where `owner` is the interned attribution key (tgid, process start time, container id) and
  `direction` is `inbound` (accepted) or `outbound` (connected). Every field keeps its observed
  value, including the ephemeral ports, so within the budget a network-observed flow can be
  matched to the host-observed connection on its full endpoints. Connections that share the
  full key within one interval share one row.
- **Fields**: interval start and end, connection count, first and last seen inside the
  interval, and bytes and packets in each direction when netprobe has the counters (null
  otherwise). Each row carries provenance: `source = netprobe`, the agent id, the netprobe
  version, the owner record, and the aggregation level.
- **Interval**: default 60 s, aligned per agent. A key with no connection in the interval emits
  nothing.
- **Budget**: a per-agent cap N on summary rows per interval (default 2,000, minimum 16). Below
  the cap nothing is aggregated. Over the cap, netprobe degrades in stages, applying each stage
  to the lowest-count rows first and stopping as soon as the interval fits:
  1. `peer_ip`: merge rows that differ only in peer port (`peer_port` null).
  2. `service`: merge rows that differ only in peer address (`peer_ip` null), leaving one row
     per owner, local endpoint, proto and direction.
  3. `overflow`: collapse the remaining rows into one overflow row per direction (at most two
     rows), keyed only by agent and direction, carrying the total connection count, bytes and
     packets, a distinct-peer estimate, the number of distinct owners and of rows collapsed.
  The overflow stage makes the cap strict: with cap N an agent emits at most N rows per
  interval, whatever its process or peer count. Merged rows keep summed counts and the
  earliest and latest times, and record their level and how many rows they absorbed. Netprobe
  counts merged rows by level and counts every interval that reached the `overflow` level. A
  connection is never omitted from every row.
- **Transport and storage**: summaries ride in the same `flow-attribution` agent batches and
  admission lane, and core publishes them on `flows.connections.summary` in a dedicated
  `flow_connections` stream (short `max_age`, transport only; it does not overlap the `flows`
  or `flow_ownership` subjects). An EventWriter processor appends them to the StarRocks
  Duplicate Key table `host_connection_summaries`, partitioned by day, under the
  `attribution` retention dataset. Rows are never updated or deleted individually.

Volume is bounded by the budget, not by connection count: at most 2,000 rows per agent per
minute, about 33 rows/s. Full keys make rows roughly one per connection per minute below the
cap. With an assumed median of 200-600 distinct full keys per host per minute, 20k hosts
produce about 67k-200k rows/s (about 6-17B rows/day), and the strict cap bounds the worst case
at about 670k rows/s. Busy listeners reach the cap and degrade to `peer_ip` or `service` rows. Phase 0 measures the per-host
distribution on the lab before this is sized.

- Alternatives considered:
  - *Restore one lease per accepted connection.* Brings the listener volume back into the
    index and the stream that Decision 1 removes. Rejected.
  - *Derive peers from NetFlow.* Unavailable in host-only deployments, and it cannot detect a
    connection that the network saw but the host did not. Rejected.
  - *Drop rows over budget.* Silent loss defeats evasion detection. Rejected in favour of
    explicit, counted aggregation.

## Known edge cases and deferred decisions

Listed so that review converges: each case has its intended handling or is explicitly
deferred.

| Case | Handling |
| --- | --- |
| Ambiguous multi-owner endpoint (two agents claim one key with overlapping validity) | Owner order decides, identically on ingest and late; counted `ambiguous` and recorded in match evidence, with an evidence-only update when the competing claim arrives second. Owners that tie on the full tuple leave the side `ambiguous` with no owner. |
| Competing claim arriving after a flow's late window closed | Not re-stamped. The shard counts the overlapping claim when it applies the lease (`late_conflict`). Deferred: whether such a claim should re-open recent flows. |
| Validity shrinking after the window closed (a `CLOSE` or `SNAPSHOT` delayed beyond the window) | Not re-stamped; the last published decision stands and the shrink is counted as `late_conflict`. Deferred: whether such a shrink should re-open recent flows. |
| History evidence expiring inside a window (a flow whose time is close to the history horizon when it is enrolled) | The expiry triggers a recomputation, which can lower the decision or return it to unattributed; counted with history evictions. |
| Flow with no monitored side whose addresses gain presence only after the flow is written | Not enrolled, so it stays `unmonitored`; the hold covers the usual race because address leases are published from netprobe start. Deferred: enrolling unmonitored flows. |
| Decision-state budget forces early finalization | The oldest states finalize with their last decision, flagged `attribution_finalized_early` on the row and counted `decision_finalized_early` per shard. Outside the arrival-order guarantee; the budget is sized so it does not occur at the stated targets. |
| Overlapping address spaces inside one partition (reused pod CIDRs) | Treated as the ambiguous case above. Deferred: whether to reject it as a configuration error (Open Questions). |
| NAT beyond node SNAT and Kubernetes public endpoints (edge SNAT, CGNAT, cloud NAT gateways) | Deferred; the flow side is `no_owner` or `unmonitored`. |
| IPv6 privacy address rotation | Address leases and wildcard re-expansion follow address changes. Deferred: prefix matching for privacy addresses. |
| Exporters with very long active timeouts | The time-T lookup uses the flow time within the skew tolerance and the history horizon. Deferred: which flow timestamp to use, and whether the horizon follows the exporter's timeout. |
| History entry evicted by its per-key cap during an enrolled flow's window | The eviction triggers a recomputation like any other candidate-set change; evictions are counted. |
| Ownership event lost on the way (dropped `CLOSE`) | Bounded by the lease TTL; the lease expires on its own. |
| Accepted socket whose owner differs from its listener but the difference is invisible to the agent | Attributed to the listener's owner (Risks). |
| Connection summaries over budget | Staged aggregation down to overflow rows, counted (Decision 9). |

**Distributed ordering.** Registration and closure snapshots make each shard's own
mutations race-free with respect to one flow. The remaining cross-shard races are deferred to
implementation, with this intended handling:

- *Shard rebalancing mid-window*: a bucket range moves with its watches; the receiving shard
  acknowledges a moved watch with a fresh snapshot, so the home shard recomputes as on
  registration.
- *Home-shard failover*: decision states are in memory on the home shard and are not
  rebuilt by replay. Flows whose state is lost keep their last published decision and are
  flagged and counted like budget-forced early finalization. Deferred: replicating open
  decision states to the warm standby.
- *Closing deadline reached*: covered above (`decision_closed_unreconciled`).

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
| Late decision update | published within 60 s of the late ownership event |
| Late decision state | <= 128 bytes per enrolled flow plus <= 24 bytes per watched key, each shard within its decision-state budget, for the full 5-minute window at 1M enrolled flows/s, with zero early finalizations |
| Rebuild | a shard of 2.5M keys is ready within 2 minutes of start |
| Connection summaries | 20k simulated agents at the per-agent budget (2,000 rows per minute) for 1 hour, no unacknowledged loss, every over-budget interval merged and counted |

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
- **Sampled flows**: sampling does not change the lookup. Should decision-state and hold caps be
  sized by sampled or by estimated flow rate?
- **Overlapping address spaces within one partition** (for example, two clusters that reuse
  the same pod CIDR under one partition): today's tie-break picks one owner and counts it
  `ambiguous`. Should overlap be a configuration error instead?
- **Cmdline in the index**: keep the redacted cmdline in memory, or keep only a hash and resolve
  the text from `flow_ownership_leases` when a flow is written?
- **Lease history at fleet scale**: at 20k agents the history table is still on the order of
  billions of rows per day. Is the 30-day default still right, or should the lease history get
  its own retention dataset?
