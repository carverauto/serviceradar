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
- **Datagram key eligibility follows Decision 12.** An unbound UDP socket without a local
  endpoint has no lease. ICMP socket/peer bindings require known addresses and zero ports,
  survive idle intervals, and end on socket close; shared keys retain socket references.
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
`snapshot_complete` to `FlowAttributionEventBatch`. The `flow-attribution` delivery source
and retained delivery stay the existing path. Agent and gateway relays must preserve the new
fields before a new producer is enabled; the wire-compatibility section is the check. During
rollout, the new decoder applies an event without `lease_op` (an old netprobe) as an `OPEN`
with a 10-minute TTL. This is only a decoding default for mixed versions; nothing is dual-written.

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
  ICMP socket/peer bindings require known local and peer addresses, use zero ports, and
  remain eligible until socket close. Shared keys retain references to their contributing
  sockets; an idle socket is not expired using the legacy observation cache TTL.
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
EventWriter workers (the shared Pipeline and FlowPipeline) already run on every
serviceradar-core replica, bound to shared durables. Only the coordinator-only duties
(ConsumerReconciler, the lag reporter, the flow correlator, and the six single-writer
streams) run under `EventWriter.CoordinatorSupervisor`. This change places the index shards
with those flow consumers and leaves those coordinator-only duties where they are. Index
shards and flow consumers scale independently: consumers by flow rate, shards by index size.

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
  final decision is a function of the candidates whose registration snapshot or notification
  the home shard processed by the window's cutoff, independent of the order in which lease
  events arrived.** A candidate applied on a remote shard before the cutoff whose notification
  reaches the home shard after it is not included (Distributed ordering). Budget-forced early finalization
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
  - *Close*: the window has one cutoff, its end (default 5 minutes after enrollment). At the
    cutoff the decision last computed by the home shard is final; it uses only the
    registration acknowledgements and notifications the home shard processed by then. If any
    registration is still unacknowledged at the cutoff, the case is counted
    (`decision_closed_unreconciled`). The home shard then drops the state and unregisters its
    watches; unregistration is cleanup only and never adds candidates. A notification, claim
    or validity shrink that reaches the home shard after the cutoff does not re-open the flow
    and is counted as `late_conflict`.
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
  `direction` for TCP is `inbound` (accepted) or `outbound` (connected). For UDP, ICMP and
  ICMPv6 it is `outbound` for a successful socket send-message operation and `inbound` for
  a successful consuming receive-message operation, per Decision 12. Every field keeps its observed
  value, including the ephemeral ports, so within the budget a network-observed flow can be
  matched to the host-observed connection on its full endpoints. Connections that share the
  full key within one interval share one row.
- **Fields**: interval start and end, connection count, first and last seen inside the
  interval, and bytes and packets in each direction when netprobe has the counters (null
  otherwise). Each row carries provenance: `source = netprobe`, the agent id, the netprobe
  version, the owner record, and the aggregation level.
  Connection count means distinct socket lifetimes for TCP and successful message operations
  for UDP/ICMP, not packets or batched API calls. Successful zero-length UDP counts; failed
  operations and receive peeks do not.
- **Interval**: default 60 s, aligned per agent. TCP connections contribute in every interval
  they overlap, including idle connections. Datagram keys contribute only in intervals with
  successful message activity. Any other key emits nothing.
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
minute, about 33 rows/s. Below the cap there is one row per distinct full key per minute.
TCP keys include idle sockets; datagram keys require successful message activity in that
minute (Decision 12). With an assumed median of 200-600 distinct full keys per host per
minute, 20k hosts produce about 67k-200k rows/s (about 6-17B rows/day), and the strict cap bounds the worst case
at about 670k rows/s. Busy listeners reach the cap and degrade to `peer_ip` or `service` rows. Phase 0 measures the per-host
distribution on the lab before this is sized.

- Alternatives considered:
  - *Restore one lease per accepted connection.* Brings the listener volume back into the
    index and the stream that Decision 1 removes. Rejected.
  - *Derive peers from NetFlow.* Unavailable in host-only deployments, and it cannot detect a
    connection that the network saw but the host did not. Rejected.
  - *Drop rows over budget.* Silent loss defeats evasion detection. Rejected in favour of
    explicit, counted aggregation.

### 10. Approved: coordinate the central cutover before enabling lease producers

Status: approved by the coordinator on 2026-10-22. This approves the plan for deploying the
already-approved straight switch. It does not authorize a rollout or waive Phase 0, and flows
remain StarRocks-only. New lease producers cannot run against old core, and the old correlator
must not write concurrently with the new attribution path. Neither combination is made safe by
adding protobuf fields, a decode or drop fallback, another producer mode, mixed central writers,
or dual-write.

Prepare the compatible gateway and agent transport first, while netprobe still sends the
old event shape. At the central cutover, drain old attribution admission and stop the old
correlator and flow consumers, with the upstream flow stream retaining incoming work. Bring
up the candidate core and EventWriter against the candidate streams and warehouse schema,
then resume consumption. Enable the candidate netprobe only after every relay and central
consumer on its route is compatible. Until then, and again whenever that route or core is the
previous release, the candidate netprobe stays stopped. Old netprobe events arriving at the
new core use Decision 1's `OPEN` / 10-minute TTL default, with no observation dual-write.

The release rehearsal must prove that the existing stream and retained-delivery capacities
cover this bounded interruption. If the drain cannot finish, the buffers cannot cover it,
or an old central writer remains active, stop the cutover. A rolling mixture of old and new
central writers is not the fallback. Roll back as described in the Migration Plan: stop
candidate lease emission before old consumers return, restore the previous release and the
previous netprobe artifact, and verify relay compatibility so that artifact's sighting
heartbeats reach the previous central release. The previous correlator needs a fresh
30-minute observation window; this is a recovery delay, not an immediate restoration of
attribution coverage.

### 11. Approved: a diagnostics prerequisite for the lab gates

**Status: approved by the coordinator on 2026-10-22.** Decision 10 and the implementation
sequence landed in PR #5934. This decision changes only the sequencing needed to obtain
Phase 0 evidence; it does not waive any numeric gate or authorize a rollout.

The read-only warehouse source retains repeated endpoint sightings but not `event_kind`,
socket direction, close/state transitions or listener-coverage relationships. Those fields
cannot be reconstructed from port-number heuristics. The available metric probe did not
find centrally retained attribution-record or cache-entry series. Therefore it cannot prove
the accepted/outbound split in task 0.1 or the full connection-summary key counts in 0.4.

Permit a separate, bounded diagnostics-only netprobe change before implementation tasks
1.x. It observes the existing socket lifecycle and owner cache while preserving the
existing attribution payloads and delivery behavior. Its measurements must use the exact
Decision 1 listener-coverage/promotion rules and Decision 9 full summary keys; it must not
substitute raw sighting counts or approximate port classifications. Coordinate ownership of
the touched netprobe files with #5752 before implementation.

The diagnostics report aggregate counts only: covered accepts, outbound and promoted keys,
projected OPEN/CLOSE/RENEW events, active local keys, history-depth distribution within the
15-minute horizon, full summary-key counts per interval, and cap-reaching intervals. Keep
diagnostic state bounded; a truncated cache, overflow, restart or incomplete warm-up marks
the affected measurement window incomplete instead of making it look cheaper. Saturated
summary counts may report an explicit lower bound above the cap, never an exact count.
Use the existing metrics path through JetStream, with bounded labels and no socket,
process, executable, address or package identifiers as metric labels. Persist only rounded,
anonymous aggregate results in this change.

The coordinator separately schedules any lab rollout. Record the observed window duration,
coverage and incomplete windows, and review that evidence against tasks 0.1 and 0.4 before
starting runtime implementation. The diagnostics are not ownership leases, production
connection summaries, a replacement attribution writer, or a fallback producer mode.
The 5 events/s, 200 bytes/key, 2-minute replay and summary-cap gates remain unchanged.
Exposure task 0.5 also remains open; these diagnostics do not supply its missing address
intervals or mapped evidence batches.

### 12. Approved: diagnostic input completeness and datagram direction

**Status: approved by the coordinator on 2026-10-23.** This fills gaps found while preparing
Decision 11 after PR #5914 merged. It does not authorize a rollout, change the capacity
targets, or permit runtime implementation before the Phase 0 gates pass.

The current `FLOW_EVENTS` input cannot certify the measurements. Both emitters in
`rust/netprobe/ebpf/src/lib.rs` suppress observations using coalesced attribution keys
before publishing them, and ring reservation failures are not counted. Records lack kernel
event timestamps. The userspace `AyaAttributionReader` starts with an empty socket inventory;
the older procfs snapshot helper is not a complete census. Current process generations can
be first-observation or exec times rather than process start times. UDP probes observe call
entry and cannot supply an unconnected receive's peer or prove successful transfer.

#### Capture and the initial population

Add a separate, bounded diagnostic observation path before attribution coalescing. Preserve
the existing attribution wire records, suppression rules, owner-cache behavior and delivery.
Diagnostic observations carry kernel monotonic time, socket lifetime identity, full
endpoints, lifecycle origin and owner-resolution status. Count failed observations and
state updates independently of the diagnostic ring so a full ring cannot hide its own loss.
Missing required hooks, unsupported layouts and failed reads are coverage failures.

Start capture before a bounded, namespace-aware census of sockets, process owners and local
addresses, then reconcile observations concurrent with that census. A census must report
errors and truncation; an empty or partial result is not proof that no sockets exist. Keep
the bootstrap's entry, byte and work limits explicit. Do not add privileges, change the
executable resolver, or alter its cache contract as an incidental diagnostic change. If
the existing privilege boundary cannot supply a required input, report that limitation for
review instead of claiming completeness.

A census can find an established TCP socket without recovering whether it was accepted or
connected, or which listener covered it. Preserve that uncertainty. The affected whole-host
measurement remains incomplete until authoritative observations resolve it or the socket
retires and its affected history ages out. Waiting fifteen minutes alone does not make an
unknown active socket known. A separately scheduled workload restart may establish a fresh
baseline, but this decision does not authorize one. Do not silently restrict the population
to sockets created after capture began or omit hosts whose windows remain incomplete.

Owner comparisons use the actual `(tgid, process start time, container id)` identity from
Decision 9. Resolve and validate process start time independently of the legacy generation
field. Distinguish confirmed host ownership from unresolved container metadata. An
unresolved identity, ambiguous socket holder or unreconciled namespace keeps the affected
measurement incomplete; it must not become a synthetic shared owner or a covered accept.
Wildcard expansion uses the reconciled address inventory, including changes during capture.

#### TCP and datagram summary direction

For TCP, retain the accepted/connected meaning of Decision 9 using lifecycle provenance,
not ports or listener presence. A connection open during any part of a minute contributes
its full key to that minute, including an idle connection. Listener coverage affects the
projected ownership events, never whether its accepted peers count toward summary capacity.

For UDP, ICMP and ICMPv6, define `outbound` as a successfully completed socket send-message
operation and `inbound` as a successfully completed consuming receive-message operation
with a known peer. Failed calls and receive peeks do not count; successful zero-length UDP
operations do count. Count individual message operations within a batched API, not the
batch call itself or the number of packets produced by segmentation or aggregation. Both
directions for the same owner and endpoints produce separate keys when both occur in an
interval. Preserve observed UDP ports; ICMP ports remain zero. The summary
`connection_count` is the number of distinct socket lifetimes for TCP and successful
message operations for these datagram protocols; byte and packet counters remain separate
and optional.

Only sockets with an eligible ownership key contribute to active keys or renewals: an
unbound UDP socket without an assigned local endpoint does not qualify. ICMP requires known
local and peer addresses for Decision 2's relaxed peer key, with zero ports; retain that
observed socket/peer binding until its socket closes. Count distinct endpoint and derived
peer keys separately, retaining reference counts when sockets share a key. A datagram
socket with an eligible ownership key can remain active while idle, but contributes no
summary key without message activity in that interval. Missing close or peer provenance
is incomplete input, not permission to expire the socket using the legacy cache's TTL.

These TCP population and datagram rules complete Decision 9's interval and direction
contract. The diagnostic must not infer
a conversation initiator from a first message, a low port, or the legacy UDP service
heuristic. Unconnected UDP still projects one local ownership lease across all peers under
Decision 1. Missing datagram receive, peer, close or owner observations prevent a complete
whole-host gate result; a TCP-only result must not pass the whole-host gates.

#### Windows, loss and delivery

Project Decision 1 events in five-second batches using event time, preserving promotions
ahead of listener changes and coalescing short OPEN/CLOSE pairs. Use the approved thirty-
minute renewal period. Report renewal volume as the analytic active-lease-seconds divided
by 1,800, separately from observed projected OPEN/CLOSE counts; do not present it as an
observed or simulated renewal schedule. Measure history
over a full fifteen-minute horizon. Report sixty-second full-key counts exactly until a
bounded set saturates above the 2,000-row cap; beyond saturation report only an explicit
lower bound and cap-reaching status. Publish the configured bounds with the measurements.

Input loss or state truncation invalidates every later window that depends on the lost
state. Recover only after a reconciled census has repaired active state and the affected
history has aged out; unresolved provenance can keep recovery incomplete for longer.
Restart and initial warm-up follow the same rule. Incomplete windows remain visible with
bounded reason codes and are excluded from gate arithmetic, with their population and
duration reported alongside the complete windows for coordinator review.

Send the aggregate records through `addon_sdk::serviceradar_metric_record`, netprobe's
existing `AddonService` stream, the agent add-on telemetry path and the gateway metrics
publisher to JetStream and EventWriter. No new metric protocol or direct database writer
is needed. The local Prometheus endpoint alone is not delivery evidence. Use fixed metric
names and finite protocol, direction, completeness-reason and history-depth bucket labels;
never put socket, process, executable, address, package or boot identifiers in labels.

The existing add-on transport is bounded and may drop a report. StarRocks metric rows do not
retain native start/reset metadata, so every value needed for the audit must be a persisted
scalar measurement. Each sixty-second report has a format-versioned fixed set of names and
finite label combinations, including explicit zeros. Its control gauges carry the format
version, a generated diagnostic session token in four exact 32-bit limbs, interval sequence,
start/end Unix seconds, and completeness with finite reason indicators. All integer values
must fit exactly in DOUBLE (at most 2^53); do not encode epoch nanoseconds as a scalar.
Use one canonical timestamp for all members of a report. Native reset metadata may be
included as supplementary context, but is not warehouse completeness evidence.

Finalize each report once and replay only identical timestamps, labels and values. Publish
at most one report per producer and interval timestamp; do not publish corrections under
the same key. Only report full intervals begun after the diagnostic session starts, so a
restart does not publish a second version of an earlier session's interval. Clock regression
or a timestamp collision invalidates gate use. The warehouse replaces rows with the same
primary key and cannot prove that conflicting duplicates never occurred; producer boundary
tests must prove immutability and restart handling instead of claiming warehouse detection.

The separately scheduled measurement must have a private expected-host roster, start/end
times and cadence independent of received metrics. Its read-only audit enumerates every
expected host/interval and left-joins the received reports, including hosts with no reports.
Missing edges, partial sets, unexplained resets and entirely absent sessions remain
unavailable or incomplete, never zero activity. Only a full expected set whose controls
agree is usable. Transport gaps do not themselves corrupt the collector's socket state,
but the missing measurements remain unavailable. Commit only rounded anonymous coverage
and results, never that private roster or raw reports.

Implementation proceeds as a bounded input/census adapter, a separate diagnostic projection
model, then native aggregate metric delivery. Synthetic lifecycle and stream-boundary tests
must prove full-key preservation, same-owner listener coverage, promotion order, identity
reuse, interval boundaries, datagram direction, saturation and recovery after loss. Existing
attribution behavior must remain unchanged. Phase 0 tasks remain open until separately
scheduled measurements meet their gates with reviewed coverage.


### 13. Approved: finite capture closure before accepting measurements

**Status: approved by the coordinator on 2026-10-23.** Decisions 11-12 authorize the
diagnostic collector. They do not specify how a finite audit proves that its last
coverage observation is final. The unpublished experimental collector cannot supply that proof.
This decision does not authorize a lab rollout, new privileges, a dependency upgrade,
or a separate BPF loader.

An ordinary interval report is provisional. An audit must also receive one immutable
terminal receipt for the same session, expected capture endpoint and final interval
sequence. That receipt certifies that every source capable of changing the accepted
prefix has finished or has made the session explicitly unavailable. Missing receipt,
partial delivery, failed proof or expired completion budget means unavailable, never
zero activity or implicit success. An earlier `complete` interval cannot bypass this
requirement. Session-wide invalidation still excludes earlier reports from that session.
Issuing the receipt must close that session token: resumed capture needs a new token
and initial proof. Contradictory evidence after termination rejects the certificate;
the implementation must not ignore late evidence merely because it already sent a receipt.

The source review found two independent closure failures:

- Disabling a map or draining the ring does not stop callbacks before the BPF program's
  own entry counter. Ordinary `membarrier(GLOBAL)` waits for ordinary RCU, while BPF
  trampoline retirement also protects instructions outside that region with RCU Tasks.
- Detaching an exit hook can suppress a successful completion before it reaches any
  diagnostic counter. A task can return from `sock_sendmsg`, pause before the exit
  callback, and resume after teardown patched that callback away. Waiting for detached
  callbacks cannot recover the missing record. The timestamp inside `emit()` is too
  late to prove that the suppressed completion belonged after the measurement endpoint.

These are properties of [trampoline teardown][closure-trampoline] and the
[x86 return/callback sequence][closure-x86], not failures that a longer grace period fixes.

**Spike result:** the bounded investigation approved as the next step is recorded in
[closure-spike.md](closure-spike.md). No examined mechanism met the obligations below.
A future proof must account for operations at entry and successful completion, retain
exit delivery through the cutoff, and establish a source-reviewed completion barrier
before issuing the terminal receipt. Pending, nested, missing or truncated operation
state must make coverage unavailable. It must not silently move a completion across an
interval boundary, discard the last interval, or treat a timeout as a barrier.

Before implementation resumes, that proof must still establish all of the following:

1. A finite cutoff that preserves or explicitly rejects every pending completion and
   every unorderable source failure, including a task paused around an exit callback.
2. A barrier supported by the pinned loader and existing privileges, with explicit
   kernel eligibility and observable failure. A version string alone is insufficient.
3. Bounded state and work, plus a bounded wait whose expiry leaves the receipt absent
   or unsuccessful. The ordinary attribution path continues independently.
4. Fixed scalar terminal membership through the existing telemetry path, with identical
   replay and an audit that rejects a missing or contradictory terminal set.
5. Synthetic negative controls for dropped completion, late loss, restart, failed
   barrier and missing receipt, including operations in progress before entry accounting
   starts and task-ID reuse. Live kernel validation remains separately scheduled.

A per-link kprobe-multi sentinel is only a candidate, not an approved mechanism.
The [older fprobe teardown][closure-old-fprobe] reaches a synchronous Tasks RCU wait;
the [upstream 6.14 shared-graph implementation][closure-new-fprobe] does not guarantee
that wait when another probe remains. Pinned Aya 0.13.1 also lacks a public multi-probe
load/attach API. A raw syscall shim or dependency change, and any restriction of the
eligible kernel population, must return as a concrete decision with spike evidence.
Neither a sentinel alone nor a successful `close()` solves the pending-exit failure.

Until this closure gate is satisfied, the collector stays exploratory and Phase 0
measurements remain unavailable for acceptance. Tasks 0.6-0.8 stay exploratory. Do not
label the prerequisite ready or start P2-P8. The recorded investigation is task 0.9 only.

[closure-trampoline]: https://kernel.googlesource.com/pub/scm/linux/kernel/git/torvalds/linux/+/refs/tags/v6.8/kernel/bpf/trampoline.c
[closure-x86]: https://kernel.googlesource.com/pub/scm/linux/kernel/git/torvalds/linux/+/refs/tags/v6.8/arch/x86/net/bpf_jit_comp.c
[closure-old-fprobe]: https://kernel.googlesource.com/pub/scm/linux/kernel/git/torvalds/linux/+/refs/tags/v6.8/kernel/trace/fprobe.c
[closure-new-fprobe]: https://kernel.googlesource.com/pub/scm/linux/kernel/git/torvalds/linux/+/refs/tags/v6.14/kernel/trace/fprobe.c

## Implementation plan

This is the reviewed implementation plan for #5738. The shared
`ExecutableOwnership` message and its initial producer/ingest path landed through
[#5919](https://github.com/carverauto/serviceradar/pull/5919). Exposure task 0.3
records that delivery. This plan does not certify live validation of that
workstream.

**Current pickup:** Decision 13's bounded source investigation found no acceptable
closure mechanism under the approved constraints. The [spike findings](closure-spike.md)
record independent bootstrap, completion-time and terminal-barrier gaps. The
[executable models](../../../build/tla/netprobe_closure/README.md) preserve the counterexamples and conditional
protocol checks; they do not prove that a kernel barrier exists. The experimental
collector remains unpublished. Tasks 0.6-0.8 and all measurement gates remain open;
resolve the source proof and review any required architecture or scope change before
expanding the collector or starting P2-P8. No lab rollout is authorized.

### PR sequence and review boundaries

Each row is a separately reviewable PR. Runtime PRs form one ordered integration stack;
they are not individually deployable releases. The coordinator releases the complete
stack only after its capacity and compatibility checks pass. New components can be tested
in isolation before final wiring; no temporary production dual-write or second correlator
is introduced to make an intermediate PR deployable.

| Order | Scope and tasks | Evidence required before advancing |
| --- | --- | --- |
| P0 | This plan and approved Decision 10 | Strict OpenSpec validation; coordinator approval of Decision 10 recorded on 2026-10-22. That approval covers the plan only and is not a deployment authorization |
| P1 | Phase 0 measurements and synthetic store/replay spike (0.1-0.5) | Median projected ownership rate <= 5 events/s/host; 2.5M-key shard including 15-minute history <= 200 bytes/key; two-hour replay ready <= 2 minutes; full summary-key distribution and cap frequency recorded, with only rounded anonymous lab measurements |
| P2 | Additive lease, address, snapshot and summary wire messages; regenerated bindings; agent relay support (1.1, transport portion of 2.1, wire portion of 5.3) | Old-producer/new-consumer decoding; complete synthetic batches survive netprobe -> agent -> gateway -> core, including `ExecutableOwnership`; protobuf breaking and generated-artifact checks |
| P3 | Ownership/summary publishers, streams, NATS permissions, history and summary warehouse processors (2.3-2.5, 5.1-5.2, 5.4-5.5) | Disjoint subjects, retention-bound refusal, whole-unit publish acknowledgement, append-only history/summary rows, retry behavior and StarRocks-required behavior |
| P4 | Bounded index, time history, owner interning, expiry, placement, replay and batched lookup (3.1-3.8) | Port reuse, duplicate/reordered events, snapshots, history eviction, budget refusal, shard movement and warming tests; measured P1 store representation carried forward |
| P5 | Netprobe lease lifecycle and bounded connection summaries, reconnect snapshots and version bumps (1.2-1.9, remainder of 2.1 and 5.3, 5.6) | Loaded-kernel TCP open/close gate; listener promotion; wildcard/address changes; renewal shedding; strict summary cap with every connection accounted for; package ownership preserved in both leases and summaries |
| P6 | Flow-tier supervision, ingest attribution, hold and late decisions, versioned warehouse updates and diagnostics (4.1-4.7, 6.1-6.2) | Protocol/topology precedence parity; cross-shard subscribe-with-snapshot; delivery permutations converge; shrink/enrichment and evidence-only updates; cutoff, budget and failover accounting; other EventWriter pipelines remain coordinator-only |
| P7 | Full capacity harness, integrated release wiring and removal of the old path (7.1-7.6, 8.1-8.4, 9.1-9.2) | All capacity targets; no acknowledged loss; exact-version artifact chain; workspace search for removed active references; release rehearsal of Decision 10 and rollback |
| P8 | Coordinator-controlled lab rollout and post-rollout verification (8.5) | Post-rollout lease, summary and attributed-flow artifacts; positive delivery control and eligible exporter overlap; every failed or inconclusive case remains explicit |

Task 2.2 belongs to the core-admission owner: this workstream supplies publisher completion
and retry contracts plus integration tests, and consumes that owner's reviewed change for
configurable concurrency and whole-unit JetStream acknowledgement. Do not edit `admission/`,
`StatusHandler` or gateway StatusBuffer as an incidental part of P3/P5/P6. P7 cannot release
until that dependency is satisfied. Matcher, threat-intel, identity/topology, Stream Load
internals and CI routing remain outside these PRs.

P1 is a build gate, not merely a benchmark to run after implementation. A failing gate is
recorded with the measured margin and a proposed design adjustment before runtime work
continues. Existing observations may lack the lifecycle/owner information needed for an
exact projection; document that limitation rather than counting repeated sightings as
connections or claiming a missing measurement passed. A successful pre-aggregation proxy
from the exposure spike does not satisfy any of these gates.

Approved Decision 11 permits the bounded diagnostics prerequisite within P1 to obtain its
missing lab measurements. It does not permit P2-P8 runtime implementation to bypass P1.

### Wire compatibility and retained delivery

- Reuse `ExecutableOwnership` on lease owner records and summaries. Keep the canonical
  assessment identity and installed version; preserve non-resolved states and provenance.
  Do not infer a package from process names or replace the shared message with a second
  schema. Overflow summaries retain Decision 9's explicitly reduced owner information.
- Allocate unused protobuf tags, preserve existing tags/reservations, and regenerate Go,
  Rust and Elixir bindings through the repository's generation targets. Keep absence of
  `lease_op` distinguishable as the legacy default. An old sighting becomes an `OPEN` with
  a 10-minute TTL only at the new decoder; an old consumer is not a supported lease decoder.
- Verify fields through the actual relay conversions, including retained retries and
  reconnects. Protobuf unknown-field behavior alone is not evidence that a JSON conversion
  or a manually reconstructed batch preserves addresses, summaries or snapshot completion.
  Do not enable a new producer through a relay that has not passed this test.
- Preserve one producer batch as one acknowledgement unit under the existing row, byte and
  deadline bounds. Splitting it by ownership bucket and summary subject cannot acknowledge
  a successful prefix. Test failure after some publishes and retry of the complete batch.
  Snapshot omission may only take effect when the complete snapshot has arrived; its
  completion marker must survive chunking, reconnect and retry without closing live leases.
- Duplicate lease delivery must leave the index unchanged. Separately verify the effect of
  retained redelivery on append-only history/summary counts; an index idempotence test does
  not prove summary-count idempotence. Any required change to the approved append-only
  storage or delivery contract is a proposed Decision before implementation.
- Bump the native add-on manifest, Bazel `NETPROBE_VERSION` and in-source producer-version
  constants together for every relevant netprobe change. A manifest-only bump cannot prove
  that the running producer contains the lease or summary implementation.

### Compatibility matrix and deployment order

| Producer and route | Central consumer | Supported behavior |
| --- | --- | --- |
| Old netprobe, old or transport-compatible relay | Old release | Existing sightings/correlator until cutover |
| Old netprobe, transport-compatible relay | New release | Legacy decode to 10-minute leases; ownership stream only; no fabricated connection summaries |
| New netprobe, compatible agent and gateway | New release | Native leases, complete snapshots, address presence and connection summaries |
| New netprobe with an old relay or old core | Either | Unsupported. The candidate netprobe stays stopped while its route or core is old; no decode, drop, or new-producer fallback |
| Any producer with old and new central attribution writers active together | Mixed | Unsupported central cutover; drain the old writers first |

Under approved Decision 10, the release runbook will use this order:

1. Prove P1-P7 on synthetic fixtures and the complete candidate stack. Compare the same
   synthetic protocol/topology cases against the existing precedence contract, including
   expected differences for late shrinkage and ambiguity; never run two production writers
   to obtain parity evidence. Verify stream capacity for the cutover and the rollback
   artifacts before changing the deployment.
2. Prepare compatible gateway and agent transports with the old netprobe still emitting
   sightings. Confirm the retained-delivery route preserves all new fields in tests.
3. Drain and stop old central attribution writers; retain incoming flow work in JetStream.
   Apply the candidate schema/stream changes and start the candidate core and EventWriter.
   Do not drop the observation table while an old correlator or observation consumer can
   still access it. Verify subject ownership, NATS permissions and replay readiness before
   resuming the candidate flow consumers.
4. Enable the matching netprobe artifact on routes whose agent, gateway and core are ready.
   Confirm reconnect snapshots and new summaries. The mixed-producer period has reduced
   host evidence for old netprobes and does not satisfy exposure's live-summary gate.
5. After rollout completion, verify exact running artifacts and use the spec's controlled
   TCP stimulus and positive delivery control. Require the resulting lease, matching flow
   and committed attributed row, plus summary evidence. Health messages or acknowledgements
   alone do not pass the gate. The coordinator performs rollout/stimulus actions; the
   exposure measurement session remains read-only on the lab.

On failure, stop candidate lease emission before old consumers return. Restore the previous
core and EventWriter and, where the route requires it, the previous gateway and agent.
Restore the previous netprobe artifact and its sighting heartbeats for the previous central
release, and verify relay compatibility before those heartbeats resume. Recreate the
observation subject, permissions, and DDL in that same coordinated rollback. A candidate
netprobe stays stopped while its route or core is old. Verify restored sighting writes
before counting the fresh 30-minute observation window. No decode or drop fallback, new
producer mode, mixed central writers, dual-write, CNPG fallback, backfill, or warehouse
rescan is part of recovery.

### Dependency back to exposure intelligence

This change supplies exposure task 0.4: the ownership index, late decisions, address
presence and `host_connection_summaries` carrying executable ownership. It does not supply
exposure's `exposure_device_addresses` intervals or per-side device ordinal/outcome columns;
those belong to exposure tasks 2.1-2.4. Exposure task 0.5 remains open until its real evidence
keys and per-batch ratios can be measured, including host summaries and mapped network
sides. Neither a raw-tuple ratio nor the existence of a summary table passes it.

Exposure Decision 21
(`openspec/changes/add-srql-exposure-intelligence/design.md`) lets the assessment
foundation in tasks 1.x proceed while the remaining Phase 0 attribution and
measurement gates still block traffic evidence integration and launch. The network
measurement still needs the later address and stamping work. This plan does not
move or waive that gate. If the measured network
ratio exceeds 25%, its approved async-view fallback must be selected before exposure
3.x; a failed host ratio requires its own design review.

## Phase 0 preflight evidence (2026-10-22)

No Phase 0 task is checked off by these preliminary results. Lab tasks 0.1 and 0.4 lack the
inputs described in Decision 11. The complete store/history and replay gates still
need measurement, and no default history cap has been selected from lab data.

### Synthetic ETS memory floor

The executable experiment lives in
`elixir/serviceradar_core/bench/ownership_store_spike_test.exs`. Each profile ran in its own
fresh OTP 28 VM on remote Bazel with 2.5M keys, approximately 20k interned owners (one per
128 keys), and 1,000-key lookup batches. All addresses, owners and distributions were invented.
Keys were 80% endpoint, 15% exact-peer and 5% relaxed-peer, with packed IPv6 addresses.
Histories contain 32-byte intervals within the 15-minute horizon, including an active interval.

| Synthetic history profile | Mean depth | Memory floor per key | Populate rate | Lookup rate |
| --- | --- | --- | --- | --- |
| One interval per key | 1.0 | ~160 bytes | ~0.6M keys/s | ~0.8M keys/s |
| 90% depth 1, 9% depth 4, 1% depth 32 | 1.6 | ~190 bytes | ~0.9M keys/s | ~1.0M keys/s |
| 70% depth 1, 25% depth 4, 5% depth 32 | 3.3 | ~270 bytes | ~0.5M keys/s | ~0.6M keys/s |

The reuse stress profile exceeds 200 bytes/key by about 70 bytes (~35%) before a complete
shard exists. The lighter profiles are lower bounds, not passing store results. The experiment
includes the key/history ETS table and both directions of owner interning. It adds the larger
of the observed VM binary-memory growth and the known off-heap binary payload to ETS word
accounting, so large history and owner binaries are not omitted. Whole-VM growth is also
reported, but no claim about resident process memory or allocator fragmentation is made.

Missing costs include expiry, snapshot membership, address-presence indexes, owner reclamation,
owner enrichment, concurrent access, shard placement and notification bookkeeping. The compact
intervals also omit connected-peer context stored outside the lookup key. Rates are single-run
table-level observations, including fixture/request construction; they are not distributed
lookup throughput, a production apply rate, or replay readiness. This memory-only experiment
did not run JetStream replay; the separate replay baseline below does. Task 0.3 cannot be
inferred by multiplying the populate rate by an event count.

All three corpus checks passed: keys did not collide, current and historical intervals resolved,
and expired/missing intervals returned no owner. A passing ExUnit result verifies the experiment;
the printed `memory_floor_gate` is the separate capacity verdict. No Rust implementation is
selected from these assumed distributions alone. Decision 2's Rust fallback remains the approved
choice if the complete, representative ETS store exceeds the gate.

Reproduce the scale run (small 25k-key corpora run by default in the benchmark targets):

```sh
bazel test -c opt --config=remote \
  //elixir/serviceradar_core:ownership_store_spike_single_test \
  //elixir/serviceradar_core:ownership_store_spike_mixed_test \
  //elixir/serviceradar_core:ownership_store_spike_reuse_test \
  --test_env=OWNERSHIP_SPIKE_KEYS=2500000 --test_output=all --test_timeout=600
```

Validation: [remote scale invocation](https://carverauto.buildbuddy.io/invocation/858965ae-f166-492f-9e2f-9ee9fe45817c).
An earlier combined-VM calibration was superseded because delayed cleanup from one profile
could contaminate the next profile's memory baseline.

### Synthetic JetStream replay baseline (2026-10-23)

`elixir/serviceradar_core/bench/ownership_replay_spike_test.exs` measures acknowledged
publishing, persistence across a graceful broker restart, and reconstruction of empty packed
ETS tables through a new explicit-ack pull consumer. All three 2.5M-key corpora passed their
correctness checks, but **all three exceeded both the 120-second replay target and the
200-byte/key memory target**. Tasks 0.2 and 0.3 remain open; this is not a complete shard.

| Invented history profile | Events over two logical hours | JSON payload | Replay time | Memory floor per active key |
| --- | --- | --- | --- | --- |
| One interval per key | ~12.5M | ~9 GB | ~151 s | ~270 bytes |
| 90% depth 1, 9% depth 4, 1% depth 32 | ~15.2M | ~11 GB | ~237 s | ~310 bytes |
| 70% depth 1, 25% depth 4, 5% depth 32 | ~23.3M | ~17 GB | ~385 s | ~390 bytes |

Replay exceeded the target by about 31, 117 and 265 seconds, respectively. Each profile
starts with 2.5M keys at logical time -7200 seconds. Four fleet-wide renewals of that
original lease follow, at -7200, -5400, -3600 and -1800 seconds. A later per-key tail then
renews an unchanged lease or closes and reuses the key so the retained 15-minute history
matches the selected depth. Six additional control events exercise duplicate closure, a
stale renewal after closure, and expiry inside/outside the history horizon. These are
invented distributions, not measurements of host activity.

The pinned NATS 2.14 server runs beside OTP 28 on the remote executor, with a file-backed,
single-replica stream, `max_age` two hours, `discard: new`, and a 24 GiB byte limit. Each JSON
message contains up to 500 events, each carrying its owner context; pulls request eight
messages. The BEAM uses four schedulers. Profiles were submitted concurrently to shared RBE,
without dedicated hardware or a CPU reservation. The link is loopback without TLS. Event time
is accelerated: this does not test two hours of wall-clock retention or a cold filesystem
cache. JSON maps and prepacked base64 keys are an experiment encoding, not a production wire
decision; address normalization and bucket routing are not measured.

The timer includes table/subscription/consumer creation, pulls, JSON decoding, owner interning,
interval updates and final acknowledgement settlement. It excludes corpus generation and
publishing, broker restart, connection setup, the final corpus scan and memory accounting.
Readiness of this experiment requires every numbered batch and independently counted event,
zero pending and unacknowledged messages, and the expected final acknowledgement sequence.
Every active key's current owner and history depth are checked after replay, together with a
historical owner on each reused key and close/expiry boundaries. A deliberately broken close
guard failed at the closed-interval lookup; the exact correct source was restored before scale.

Memory includes the key/history table and both owner-interning tables, plus the larger of VM
binary-memory growth and known off-heap history/owner payload. Whole-VM growth was approximately
0.7, 0.8 and 1.0 GB, respectively; resident memory, allocator fragmentation and the separate
broker are not measured by this figure. These values include allocations from decoding and
incremental updates, with a different serialized owner context from the preloaded experiment.
They are not a production regression comparison or an explanation of the allocation difference.

Missing shard costs remain expiry scheduling, snapshot membership and omission handling,
address-presence indexes, owner reclamation/enrichment, placement, notifications, budgets and
concurrent readers/writers. The experiment prunes against a fixed replay-time cutoff, and does
not prove all production ordering, snapshot or replay-to-live handoff semantics. Passing ExUnit
checks confirms corpus reconstruction; the printed timing/memory verdicts are separate. No
default history cap or Rust implementation is selected from these assumed profiles. Before
accepting P1, the complete representative store and replay path must meet the original gates;
any architecture adjustment still requires a concrete reviewed decision.

Evidence for this uninstrumented baseline: [all three scale runs](https://carverauto.buildbuddy.io/invocation/36684ef2-51b7-4560-8892-f463319a71d1),
[small corpus checks](https://carverauto.buildbuddy.io/invocation/4ac6a3cf-4ae6-456a-a527-e351b34c2076),
and [close-guard negative control](https://carverauto.buildbuddy.io/invocation/82e8a2fc-5111-41cc-a75f-ff96b446f6a6).
That run submitted the three scale targets together. Default 2,500-key runs only check correctness:

```sh
bazel test -c opt --config=remote \
  //elixir/serviceradar_core:ownership_replay_spike_single_test \
  //elixir/serviceradar_core:ownership_replay_spike_mixed_test \
  //elixir/serviceradar_core:ownership_replay_spike_reuse_test \
  --test_env=OWNERSHIP_REPLAY_KEYS=2500000 --test_timeout=1800 \
  --test_output=all --flaky_test_attempts=1
```

Those targets now print `protocol=2` and time phase instrumentation inside replay, so this
command does not reproduce the table. The [replay cost investigation](replay-costs.md) records
that instrumented protocol, the copy modes and the later measurements. It keeps this corpus,
its correctness checks and the original gates.

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

**Distributed ordering.** Registration snapshots make each shard's own mutations race-free
with respect to one flow up to the window's single cutoff. The remaining cross-shard races are deferred to
implementation, with this intended handling:

- *Shard rebalancing mid-window*: a bucket range moves with its watches; the receiving shard
  acknowledges a moved watch with a fresh snapshot, so the home shard recomputes as on
  registration.
- *Home-shard failover*: decision states are in memory on the home shard and are not
  rebuilt by replay. Flows whose state is lost keep their last published decision and are
  flagged and counted like budget-forced early finalization. Deferred: replicating open
  decision states to the warm standby.
- *Lease applied remotely before the cutoff, notified after it*: the candidate is not part of
  the final decision and the late notification is counted as `late_conflict`. Deferred:
  whether to wait for in-flight notifications, which would extend the window.
- *Registration still unacknowledged at the cutoff*: covered above
  (`decision_closed_unreconciled`).

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
state is ephemeral, and only the team's own deployments run flow attribution. Approved
Decision 10 (2026-10-22) is the no-overlap cutover and rollback order for that switch. The
approval is of the plan only and does not authorize deployment.

1. Ship netprobe and agent lease emission, the ownership publisher and stream, the index, and
   on-ingest attribution in the same release, with the correlator deleted in that release.
   Enable them only in the Decision 10 order: a candidate netprobe stays stopped until every
   relay and central consumer on its route is compatible.
2. While old netprobe versions roll forward against the new core, their events decode as
   `OPEN` with a 10-minute TTL (Decision 1). Their heartbeats keep those leases alive until
   the agent upgrades.
3. After the old correlator and observation consumers are stopped, drop
   `flow_process_attribution_observations` and remove `flows.attribution.observations`
   from the `flows` stream, the NATS permissions and the EventWriter config. Create
   `flow_ownership_leases` and the `flow_ownership` stream.
4. Run the post-rollout verification against the lab.

Rollback: stop candidate lease emission before old consumers return, then redeploy the
previous release together with the previous netprobe add-on. Verify relay compatibility
before that artifact resumes sighting heartbeats; the previous central release needs those
heartbeats. A candidate netprobe stays stopped while its route or core is the previous
release. The correlator works again once 30 minutes of new observations have arrived. Flows
written while this change was live remain attributed. The dropped observation table is
recreated by its DDL. No decode or drop fallback, new producer mode, mixed central writers,
dual-write, CNPG fallback, backfill, or warehouse rescan is part of recovery.

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
