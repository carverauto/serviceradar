## ADDED Requirements

### Requirement: Agents Emit Socket Ownership Leases Instead Of Sightings
Netprobe SHALL publish socket ownership as leases keyed on the local endpoint `(proto, local_ip, local_port)`, using the operations `OPEN`, `RENEW`, `CLOSE` and `SNAPSHOT`, and MUST NOT re-emit an unchanged lease on a heartbeat shorter than the renewal period.
Each lease event SHALL carry `first_seen`, `last_seen`, a TTL, and the owner (`pid`, `tgid`, `uid`, `comm`, redacted command line, `container_id`, and workload identity when known). The renewal period SHALL default to 30 minutes and the TTL to twice the renewal period. An accepted connection whose owner matches its listener's owner MUST NOT produce its own lease; when the owners differ, netprobe SHALL emit an exact peer entry keyed on that connection's full 5-tuple, including the local port. Before netprobe emits a `CLOSE` for a listener lease, or an `OPEN` that gives the listener key a new owner, it SHALL emit, in the same batch and ahead of that event, an exact peer entry carrying the accepted socket's own `first_seen` and owner for every accepted socket the listener lease covered that is still open. Netprobe SHALL expand a wildcard listener into one lease per local address, SHALL publish its local addresses as address leases, and SHALL re-expand its wildcard leases when those addresses change. An `OPEN` and `CLOSE` for the same key within one agent batch window SHALL be coalesced into a single event. Netprobe SHALL send a `SNAPSHOT` of all active leases on start and after its agent reconnects. Netprobe SHALL enforce a per-agent event budget, MUST shed lease renewals before new outbound keys and MUST NOT shed listener or address leases, and SHALL count every shed event by reason. Shedding a renewal MUST NOT extend or truncate a lease's validity beyond the `last_seen` plus TTL of its last delivered event. The command line SHALL be the redacted value capped at 256 bytes.

#### Scenario: A busy listener is one lease
- **GIVEN** a process listens on 192.0.2.10:443/TCP and accepts thousands of connections over 30 minutes from clients in 198.51.100.0/24
- **AND** every accepted socket has the listener's owner
- **WHEN** netprobe publishes ownership for that period
- **THEN** it publishes one `OPEN` for the listener key and at most one `RENEW` per renewal period
- **AND** it publishes no event per accepted connection

#### Scenario: Accepted connection with a different owner
- **GIVEN** a listener on 192.0.2.10:8080/TCP hands an accepted connection from 198.51.100.7:51000 to a process with a different tgid
- **WHEN** netprobe resolves the accepted socket's owner
- **THEN** it publishes an exact peer entry for `(tcp, 192.0.2.10, 8080, 198.51.100.7, 51000)` carrying that process as owner

#### Scenario: Listener closes during graceful shutdown
- **GIVEN** process A listens on 192.0.2.10:8080/TCP and holds an accepted connection from 198.51.100.7:51003 with the listener's owner
- **WHEN** A closes its listener while the accepted connection stays open, and process B later binds 192.0.2.10:8080
- **THEN** netprobe publishes an exact peer entry `(tcp, 192.0.2.10, 8080, 198.51.100.7, 51003)` owned by A ahead of the listener's `CLOSE`
- **AND** a flow on that connection after the listener closed is attributed to A, also after B's listener lease exists

#### Scenario: Short-lived outbound connection costs one event
- **GIVEN** a process opens a TCP connection from 192.0.2.20:40001 to 198.51.100.9:443 and closes it within one batch window
- **WHEN** netprobe publishes the batch
- **THEN** the batch carries one coalesced `OPEN` for key `(tcp, 192.0.2.20, 40001)` with `last_seen` and a closed flag
- **AND** it carries no separate `CLOSE` for that key

#### Scenario: Wildcard listener is expanded by the agent
- **GIVEN** a host with addresses 192.0.2.30 and 192.0.2.31 runs a listener on 0.0.0.0:53/UDP
- **WHEN** netprobe publishes the listener
- **THEN** it publishes `bound` leases for `(udp, 192.0.2.30, 53)` and `(udp, 192.0.2.31, 53)`
- **AND** when 192.0.2.31 is removed from the host it closes that address lease and the lease expanded from it

#### Scenario: Agent exceeds its ownership budget
- **GIVEN** an agent's ownership events exceed its configured per-agent budget
- **WHEN** netprobe sheds events to stay within the budget
- **THEN** it sheds renewals of known leases before new outbound keys
- **AND** it does not shed listener or address leases
- **AND** it increments a shed counter labeled by reason

### Requirement: Socket Ownership Changes Flow Through JetStream
Core SHALL publish every admitted ownership batch on JetStream subjects `flows.ownership.<bucket>`, where `<bucket>` is one of 256 fixed buckets derived from the hash of `(partition, ip)`, in a dedicated `flow_ownership` stream whose `max_age` is at least the lease TTL plus the larger of the renewal period and the history horizon, plus a safety margin (default 2 hours). The stream MUST refuse new publishes when it reaches its byte limit rather than discard retained events. Core MUST NOT write ownership events directly to CNPG or StarRocks.
The publisher SHALL derive node-SNAT peer entries from outbound `connected` leases whose local address is not one of the agent's registered node addresses, SHALL place each derived entry on the bucket of its own key, and SHALL keep the existing per-message row and byte caps. The `flow_ownership` stream subjects MUST NOT overlap the `flows` stream subjects.

#### Scenario: Ownership batch is admitted
- **GIVEN** an agent delivers an ownership batch through the `flow-attribution` source
- **WHEN** core admits the batch
- **THEN** it publishes each event on the bucket subject derived from the event's `(partition, ip)`
- **AND** no CNPG or StarRocks table is written by core

#### Scenario: Pod-local outbound connection produces a node-SNAT entry
- **GIVEN** an agent whose registered node address is 192.0.2.40 reports an outbound lease from pod address 198.51.100.50:42000 to 192.0.2.99:5432/TCP
- **WHEN** core publishes the lease
- **THEN** it also publishes a peer entry `(tcp, 192.0.2.40, 192.0.2.99, 5432)` on the bucket of 192.0.2.40

### Requirement: Endpoint Ownership Index Is Keyed Sharded And Bounded
The system SHALL maintain an in-memory endpoint ownership index that maps endpoint keys `(partition, proto, ip, port)`, exact peer keys `(partition, proto, ip, port, remote_ip, remote_port)` and relaxed peer keys `(partition, proto, ip, remote_ip, remote_port)` to a time-bounded validity history per key, plus an address presence count per `(partition, ip)`, fed only from the `flow_ownership` stream. Relaxed peer keys SHALL be used only for ICMP, relaxed UDP and node-SNAT entries; an accepted connection's exact peer entry MUST keep its local port.
Each lease SHALL reference an interned owner record. Workload identity SHALL be resolved once per owner record when the record is created, and identity carried on the event SHALL take precedence. A lookup at time T SHALL return the lease whose validity interval contains T within the configured skew tolerance (default 5 seconds). When more than one lease qualifies, the lookup SHALL choose deterministically (container id present, then most recent `first_seen`, then `agent_id`, then `pid`) and SHALL report the result as ambiguous. Every closed or expired lease whose interval ended within the configured history horizon (default 15 minutes) SHALL remain resolvable, regardless of how many owners the key had in that time. A per-key history cap (default 32 entries), sized from the horizon and the shard's byte budget, SHALL bound a single key; on overflow the shard SHALL evict entries whose interval ended beyond the horizon first, then the oldest entry inside the horizon, and MUST count every eviction inside the horizon. Leases not renewed within their TTL SHALL expire without a scan. The 256 buckets SHALL be grouped into shards, each with one active owner and an optional warm standby. Each shard MUST stay within its configured entry and byte budget, MUST refuse new outbound `connected` leases before `bound` leases when the budget is reached, and MUST count every refusal. On start a shard SHALL rebuild by replaying its bucket subjects, SHALL restore every lease still within its TTL and every closed or expired lease still inside the history horizon, and SHALL report `index_warming` for lookups until the replay completes. A shard MUST refuse to start against a stream whose `max_age` is below that bound. A `SNAPSHOT` SHALL close the agent's leases it omits at the snapshot's time and MUST NOT delete them or shorten an interval before that time. Small and single-node installations SHALL use the same shard layout with every shard placed on one node.

#### Scenario: Port reuse resolves by time
- **GIVEN** key `(tcp, 192.0.2.20, 40001)` was owned by process A until 10:00:00 and by process B from 10:00:30
- **WHEN** a flow at 09:59:50 and a flow at 10:00:40 are looked up
- **THEN** the first resolves to process A
- **AND** the second resolves to process B

#### Scenario: A reused key keeps every owner inside the horizon
- **GIVEN** key `(tcp, 192.0.2.20, 40003)` had five successive owners A to E between 10:00 and 10:10, each closed before the next opened
- **WHEN** a flow from the interval of owner A is looked up at 10:12
- **THEN** it resolves to owner A
- **AND** no history eviction is counted

#### Scenario: Per-key history cap is exceeded
- **GIVEN** a key holds as many entries as its per-key cap, all with intervals that ended inside the history horizon
- **WHEN** another lease for that key is applied
- **THEN** the oldest entry is evicted
- **AND** the history eviction counter increments

#### Scenario: Shard reaches its memory budget
- **GIVEN** a shard is at its configured byte budget
- **WHEN** a new outbound `connected` lease and a new listener lease arrive
- **THEN** the shard refuses the outbound lease before the listener lease and counts the refusal
- **AND** the shard's memory does not exceed its budget

#### Scenario: Shard restarts
- **GIVEN** a shard process restarts
- **WHEN** it replays its bucket subjects from the `flow_ownership` stream
- **THEN** every lease still within its TTL and every closed lease still inside the history horizon is restored
- **AND** lookups return `index_warming` until the replay completes

#### Scenario: Lease outlives its last event across a restart
- **GIVEN** an agent last renewed lease `(tcp, 192.0.2.10, 443)` at 10:00 with a 60-minute TTL and then disconnected
- **WHEN** the shard owning that key restarts at 10:46 and replays its subjects
- **THEN** the lease is restored and a flow at 10:50 resolves to its owner
- **AND** the lease expires at 11:00 as it would have on a shard that never restarted

#### Scenario: Lease is not renewed
- **GIVEN** an agent stops sending events and its leases are not renewed
- **WHEN** a lease's TTL elapses
- **THEN** the lease expires from the index without a scan of the index

### Requirement: Flows Are Attributed On Ingest By Key Lookup
The EventWriter flow processor SHALL attribute each flow before its single StarRocks write by looking up the flow's source and destination endpoints in the ownership index, issuing at most one batched lookup per shard per flow batch, and MUST NOT run a periodic join of stored flows against ownership data.
The original endpoint of every flow side SHALL be looked up. A side that matches the cached public endpoint map SHALL also have its backend endpoints looked up in the same batch; backend candidates SHALL be considered only when the original endpoint has no candidate at the exact, listener-or-relaxed or node-SNAT rank, and MUST NOT displace an exact owner of the original endpoint. The flow row SHALL be written once, carrying `event_type = attributed_flow` and the owner columns when an owner is found. The flow processor SHALL be able to run on multiple nodes against the shared durable flow consumer, and adding nodes SHALL increase attribution throughput without changing the shard layout.

#### Scenario: Router flow to a monitored listener
- **GIVEN** the index holds a `bound` lease for `(tcp, 192.0.2.10, 443)`
- **WHEN** a router-exported flow from 198.51.100.7:51000 to 192.0.2.10:443 reaches the flow processor
- **THEN** the processor writes the flow once with the listener's owner and `event_type = attributed_flow`
- **AND** no partial update of that flow row is issued

#### Scenario: No periodic global join
- **WHEN** flow attribution runs at any flow rate
- **THEN** no scheduled job reads stored flows to match them against ownership data

#### Scenario: Public VIP resolves through the endpoint map
- **GIVEN** the public endpoint map sends 203.0.113.80:443/TCP to the backend 192.0.2.60:8443
- **AND** the index holds a `bound` lease for `(tcp, 192.0.2.60, 8443)`
- **WHEN** a flow to 203.0.113.80:443 is attributed
- **THEN** the flow is written with the backend's owner and the public endpoint context

#### Scenario: Exact owner of a VIP address outranks its backend mapping
- **GIVEN** the public endpoint map sends 203.0.113.80:443/TCP to the backend 192.0.2.60:8443, which has a `bound` lease
- **AND** the index holds an exact peer entry `(tcp, 203.0.113.80, 443, 198.51.100.7, 51000)`
- **WHEN** a flow from 198.51.100.7:51000 to 203.0.113.80:443 is attributed
- **THEN** the flow is written with the exact peer entry's owner and the exact strategy
- **AND** the backend's owner is not selected

#### Scenario: One client reaches two local ports owned by different workers
- **GIVEN** a listener on 192.0.2.10 owns `bound` leases for `(tcp, 192.0.2.10, 8080)` and `(tcp, 192.0.2.10, 8443)`
- **AND** the index holds exact peer entries `(tcp, 192.0.2.10, 8080, 198.51.100.7, 51000)` owned by worker A and `(tcp, 192.0.2.10, 8443, 198.51.100.7, 51000)` owned by worker B
- **WHEN** flows from 198.51.100.7:51000 to 192.0.2.10:8080 and to 192.0.2.10:8443 are attributed
- **THEN** the first is written with worker A and the second with worker B, both as exact matches
- **AND** neither flow is attributed to the listener's owner

### Requirement: Late Binding Is Bounded And Never Rescans Flows
A flow side SHALL be monitored when its address has address presence, or when it matches the public endpoint map and any mapped backend address has address presence; the backend keys of a monitored VIP side SHALL be used for hold, late-decision enrollment, home-shard placement and watches alongside its original keys. The flow processor SHALL hold a flow with a monitored side without a matching lease for at most the configured hold window (default 5 seconds, maximum 30 seconds, and always below the consumer acknowledgement deadline), and MUST NOT hold a flow that has no monitored side.
A flow still unmatched after the hold, or one written because the hold buffer reached its item or byte cap, SHALL be written unattributed. Every flow written with a monitored side, attributed or not, SHALL be enrolled once for a late decision in its home shard (the shard of its source side, or of its destination when only the destination is monitored; for a monitored VIP side that is not an agent address, the shard of its first mapped backend) for the late window (default 5 minutes); a flow carrying agent-provided attribution MUST NOT be enrolled, and no decision SHALL be finalized before its window closes except by the budget degradation below. Precedence SHALL be the full ordering tuple of rank, side and owner order, with the source side ahead of the destination side at equal rank and the index's deterministic owner tie-break (container id present, most recent `first_seen`, `agent_id`, `pid`) as the owner order, applied identically on ingest and in late decisions; an unattributed flow SHALL have the lowest precedence. For a flow whose decision state is retained for its full late window, the final decision MUST be a function of the candidate set as it stands when the window closes, independent of the order in which lease events arrived. Whenever any change to the candidate set of an enrolled flow's keys occurs during the window, on any shard, including a lease that starts to cover the flow's time, a validity interval shortened by a delayed `CLOSE` or a `SNAPSHOT`, a history entry removed by horizon expiry or the per-key cap, and an owner-attribute change (command line, container id or workload identity) to a lease that covers the flow's time, the home shard SHALL recompute the decision from the full candidate set of both sides: the winner by full precedence and, as ambiguity evidence, the number of other owners tying with it on rank and side; distinct owners tying on the full tuple SHALL leave the side ambiguous with no owner. The home shard SHALL publish an update on `events.flow.attribution` whenever the decision differs in any way from the last published one, including a lower winner, changed owner context for the same winning lease, a return to unattributed, a change between unambiguous and ambiguous, and new ambiguity evidence with an unchanged winner. Each update SHALL carry the decision's precedence and ambiguity evidence and a per-flow decision sequence that the home shard increments with every publication, the ingest-written row being sequence 0. EventWriter SHALL apply an update as a partial primary-key update only when its decision sequence is greater than the row's stored decision sequence, so the row converges on the latest decision and an obsolete higher-precedence attribution MUST NOT survive a later decision. At window close the last published decision SHALL be final. Late decisions for one flow MUST be published only by its home shard. Each decision state SHALL take at most 128 bytes, and each shard SHALL bound decision state by an entry and byte budget sized so that early finalization does not occur at the stated capacity targets. When the budget binds, the oldest states SHALL finalize early with their last decision; the home shard SHALL set the SRQL-visible flag `attribution_finalized_early` on each such flow row and MUST count every early finalization per shard. The arrival-order guarantee applies only to flows whose state was retained for the full window. The system MUST NOT read stored flows back to find unattributed ones.

#### Scenario: Flow races its ownership event
- **GIVEN** a flow from 192.0.2.20:40002 arrives 2 seconds before the agent's `OPEN` for that key
- **WHEN** the `OPEN` arrives within the hold window
- **THEN** the flow is written once, attributed
- **AND** no late stamp is issued for it

#### Scenario: Flow to an unmonitored address is not held
- **GIVEN** neither endpoint of a flow is a monitored address
- **WHEN** the flow reaches the flow processor
- **THEN** it is written immediately with outcome `unmonitored`

#### Scenario: Ownership arrives after the hold
- **GIVEN** a flow involving monitored address 192.0.2.20 was written unattributed after its hold expired
- **WHEN** a lease covering the flow's time arrives within the late window
- **THEN** the shard publishes a versioned update on `events.flow.attribution`
- **AND** the flow row becomes `attributed_flow`

#### Scenario: Late leases on both sides resolve by precedence
- **GIVEN** a flow from 192.0.2.20:40004 to 192.0.2.10:443 was written unattributed after its hold expired
- **AND** a `connected` lease for `(tcp, 192.0.2.20, 40004)` whose remote is 192.0.2.10:443 arrives, and later a `bound` lease for `(tcp, 192.0.2.10, 443)` arrives on another shard
- **WHEN** the late stamps are decided
- **THEN** the flow's home shard publishes the exact source-side owner
- **AND** no update carrying the destination listener's owner is published for the flow

#### Scenario: Destination exact lease arrives before the source exact lease
- **GIVEN** a flow from 192.0.2.20:40005 to 192.0.2.10:8080 was written unattributed after its hold expired
- **AND** an exact peer entry `(tcp, 192.0.2.10, 8080, 192.0.2.20, 40005)` arrives first, and later in the late window a `connected` lease for `(tcp, 192.0.2.20, 40005)` whose remote is 192.0.2.10:8080 arrives
- **WHEN** the late stamps are decided
- **THEN** the home shard first publishes the destination owner and keeps the decision state open
- **AND** it then publishes the source owner, which EventWriter applies because its decision sequence is higher
- **AND** the flow row ends with the source-side owner

#### Scenario: Exact worker lease arrives after a listener attribution on ingest
- **GIVEN** the index holds a `bound` lease for `(tcp, 192.0.2.10, 8080)` owned by the listener process
- **AND** a flow from 198.51.100.7:51002 to 192.0.2.10:8080 is written on ingest with the listener's owner
- **WHEN** an exact peer entry `(tcp, 192.0.2.10, 8080, 198.51.100.7, 51002)` owned by a worker process arrives seconds later, within the late window
- **THEN** the home shard publishes the worker's attribution with exact precedence
- **AND** the flow row ends with the worker as its owner

#### Scenario: The same candidates in either arrival order give the same final decision
- **GIVEN** agents A and B both hold `bound` leases for `(tcp, 192.0.2.10, 443)` with overlapping validity, A from 10:00 and B from 10:05, and neither carries a container id
- **AND** a flow from 198.51.100.7:51005 to 192.0.2.10:443 at 10:06 is written on ingest while only one of the two leases has arrived
- **WHEN** the run is repeated once with A arriving first and once with B arriving first, the other lease arriving within the late window each time
- **THEN** both runs end with B as the owner and the flow recorded as ambiguous with one competing owner
- **AND** in the run where B arrived first, the update after A arrives is evidence-only and keeps B as the owner

#### Scenario: Exact source attribution on ingest stays open for a competing claim
- **GIVEN** a flow from 192.0.2.20:40006 to 198.51.100.9:443 is written on ingest with agent A's exact source-side `connected` lease for `(tcp, 192.0.2.20, 40006)`, with `first_seen` 10:00
- **WHEN** agent B's overlapping exact lease for the same key, with `first_seen` 10:01, arrives within the late window
- **THEN** the home shard publishes B as the owner, because B is earlier in owner order
- **AND** the final decision matches the one made had B's lease arrived first

#### Scenario: Owners that tie on the full tuple leave the side ambiguous
- **GIVEN** two distinct owners hold candidates for one flow side that tie on rank, side and owner order
- **WHEN** the decision is computed
- **THEN** that side carries no owner and is recorded as ambiguous
- **AND** the result is the same in either arrival order

#### Scenario: Decision state budget binds
- **GIVEN** a shard's decision state is at its entry or byte budget
- **WHEN** another flow is enrolled
- **THEN** the oldest state finalizes early with its last decision
- **AND** that flow row is flagged `attribution_finalized_early`
- **AND** the shard's early-finalization counter increments

#### Scenario: Delayed CLOSE removes a winning candidate
- **GIVEN** a flow from 192.0.2.20:40007 to 192.0.2.10:443 at 10:00:10 is written on ingest with the exact source-side owner of `(tcp, 192.0.2.20, 40007)`, whose lease was still open
- **AND** the index also holds a `bound` lease for `(tcp, 192.0.2.10, 443)`
- **WHEN** a delayed `CLOSE` for `(tcp, 192.0.2.20, 40007)` at 10:00:00 arrives within the flow's late window
- **THEN** the home shard recomputes the decision and publishes the destination listener's owner with a higher decision sequence
- **AND** the flow row ends with the listener's owner, the same final decision as when the `CLOSE` arrives before the flow

#### Scenario: Owner enrichment after the flow updates its process context
- **GIVEN** a flow from 198.51.100.7:51006 to 192.0.2.10:443 is written on ingest with the owner of the `bound` lease for `(tcp, 192.0.2.10, 443)`, whose owner record has no command line yet
- **WHEN** an enrichment `OPEN` for the same key and `first_seen` adds the redacted command line within the flow's late window
- **THEN** the home shard publishes an update with the enriched owner context and a higher decision sequence
- **AND** the flow row ends with the same process context as when the enrichment arrives before the flow

#### Scenario: An older decision does not override a newer one
- **GIVEN** a flow row carries the decision with decision sequence 3
- **WHEN** an update with decision sequence 2 and a higher precedence reaches EventWriter late
- **THEN** the row keeps decision sequence 3

#### Scenario: Backend lease arrives after a flow to a public VIP
- **GIVEN** the public endpoint map sends 203.0.113.80:443/TCP to the backend 192.0.2.60:8443, and 192.0.2.60 has address presence
- **AND** a flow from 198.51.100.7:51004 to 203.0.113.80:443 is written unattributed after its hold expired
- **WHEN** a `bound` lease for `(tcp, 192.0.2.60, 8443)` arrives within the late window
- **THEN** the flow's home shard, the shard of 192.0.2.60, publishes the backend's owner with public-endpoint precedence
- **AND** the flow row becomes `attributed_flow` with the public endpoint context

#### Scenario: Late window closes
- **GIVEN** a flow's late window has ended
- **WHEN** a lease covering the flow's time arrives
- **THEN** the flow's last published decision stays final
- **AND** no stored flows are read to revisit it

### Requirement: Agent-Local Attribution Takes Precedence
When a flow arrives already attributed by the agent that produced it, the flow processor SHALL keep that attribution and MUST NOT replace it with an index lookup for the side the agent owns. Flows from routers, switches and other exporters SHALL be attributed through the ownership index. This requirement MUST NOT reintroduce central-to-agent flow replay.

#### Scenario: Agent-attributed flow keeps its owner
- **GIVEN** an agent publishes a flow that already carries attribution for its local endpoint 192.0.2.70:43000
- **WHEN** the flow processor handles it
- **THEN** the flow keeps the agent-provided owner for that side
- **AND** the processor does not look up 192.0.2.70:43000 in the index

### Requirement: Ownership Lease History Is Append-Only
EventWriter SHALL append one row per ownership event to the StarRocks Duplicate Key table `flow_ownership_leases`, partitioned by day. Rows MUST NOT be updated or deleted individually. Expiry SHALL happen by dropping whole partitions under the `attribution` warehouse retention dataset.

#### Scenario: Ownership history for incident response
- **GIVEN** a process owned 192.0.2.10:443/TCP during the retained span
- **WHEN** an operator queries the lease history for that endpoint
- **THEN** the rows show the owner and the lease's `first_seen` and `last_seen`
- **AND** no row-level DELETE or UPDATE was issued against the table

### Requirement: Hosts Report Per-Process Connection Summaries As Evidence
Netprobe SHALL emit, per interval (default 60 seconds), one connection summary per `(agent, owner, local_ip, local_port, peer_ip, peer_port, proto, direction)` that had at least one connection in the interval, keeping every key field, including ephemeral ports, at its observed value. Netprobe MUST NOT aggregate summaries while the agent's interval is within its budget. A summary SHALL carry the interval, the connection count, the first and last seen times inside the interval, bytes and packets per direction when available, and provenance (source, agent id, netprobe version, owner record and aggregation level). Accepted connections covered by a listener lease SHALL still be counted in per-peer summaries. Summaries SHALL travel through the `flow-attribution` admission lane and a dedicated JetStream stream, and EventWriter SHALL append them to the StarRocks Duplicate Key table `host_connection_summaries`, partitioned by day, under the `attribution` retention dataset; rows MUST NOT be updated or deleted individually. Netprobe SHALL enforce a per-agent cap N on summary rows per interval (default 2,000, minimum 16) so that it never emits more than N rows in an interval, regardless of its process or peer count. Over the cap it SHALL degrade in stages, lowest-count rows first and stopping as soon as the interval fits: merge across peer ports, then across peer addresses, then collapse the remaining rows into at most one overflow row per direction that carries the total connection count, bytes and packets, a distinct-peer estimate, and the number of distinct owners and rows collapsed. It SHALL record the aggregation level and absorbed-row count on each merged row, count merged rows by level, and count every interval that reached the overflow level; it MUST NOT drop a connection from every row. The ownership index MUST NOT read connection summaries, and attribution MUST NOT depend on them.

#### Scenario: Host-only deployment lists a process's peers
- **GIVEN** a deployment with StarRocks and netprobe agents but no flow exporters
- **AND** a process on 192.0.2.80 connected to 198.51.100.20:5432/TCP and 198.51.100.21:443/TCP between 10:00 and 10:05
- **WHEN** an operator queries `host_connection_summaries` for that process and interval
- **THEN** the rows list both peers with their connection counts and first and last seen times

#### Scenario: Accepted connections still yield per-peer summaries
- **GIVEN** a listener on 192.0.2.10:443/TCP accepts connections from 198.51.100.7:51000, 198.51.100.7:51001 and 198.51.100.8:52000 in one interval
- **AND** every accepted socket has the listener's owner, so no lease is emitted for them
- **AND** the agent's interval is within its summary budget
- **WHEN** netprobe emits the interval's summaries
- **THEN** it emits three `inbound` summaries for local endpoint 192.0.2.10:443, one per peer endpoint with its observed peer port
- **AND** no row is aggregated

#### Scenario: Summary budget overflow is counted and visible
- **GIVEN** an agent has more distinct summary keys in one interval than its per-agent cap
- **WHEN** netprobe emits the interval's summaries
- **THEN** it merges rows until the cap holds and marks each merged row with its aggregation level and absorbed-row count
- **AND** the merged-row counter increments by level
- **AND** the total connection count across the interval's rows equals the observed connection count

#### Scenario: More processes than the summary cap
- **GIVEN** an agent configured with a summary cap of 100 rows per interval
- **AND** 150 distinct processes each make one outbound connection in the interval
- **WHEN** netprobe emits the interval's summaries
- **THEN** it emits at most 100 rows, including an `overflow` row for the outbound direction
- **AND** the overflow row carries the collapsed connection count, a distinct-peer estimate, and the number of owners and rows it collapsed
- **AND** the overflow-interval counter increments

### Requirement: Attribution Meets Fleet-Scale Capacity Targets
Flow attribution SHALL sustain at least 1M flows/s attributed across horizontally scaled flow-tier nodes. It SHALL sustain ownership ingest from 20k agents, SHALL keep index memory at no more than 200 bytes per active key on average, and SHALL add no more than 250 ms p99 latency per flow batch for flows whose owner is present. Each target SHALL be verified with a synthetic load harness that uses only invented addresses from documentation ranges.

#### Scenario: Attribution throughput scales out
- **GIVEN** the load harness drives synthetic flows against an index populated for 20k simulated hosts
- **WHEN** the number of flow-tier nodes is doubled, until the warehouse write limit is reached
- **THEN** the attributed throughput grows by at least 1.6x
- **AND** the aggregate attribution stage reaches at least 1M flows/s

#### Scenario: Ownership ingest from 20k agents
- **GIVEN** 20k simulated agents each emit ownership events at the measured per-host rate of at least 5 events/s
- **WHEN** the load runs for one hour
- **THEN** no acknowledged ownership event is lost
- **AND** ownership consumer lag stays at or below 5 seconds at p99

#### Scenario: Index memory stays proportional to active sockets
- **GIVEN** the index holds 40M active keys across its shards
- **WHEN** shard memory is measured
- **THEN** the average is no more than 200 bytes per active key
- **AND** every shard is within its configured budget

#### Scenario: Shard rebuild time
- **GIVEN** a shard owning 2.5M active keys restarts
- **WHEN** it replays its bucket subjects
- **THEN** it reports ready within 2 minutes

### Requirement: Ownership Index And Enrichment Health Is Observable
The ownership index and the flow attribution stage SHALL publish their health as metrics through the JetStream metrics pipeline, with labels that MUST NOT include agent identifiers, process identifiers, IP addresses, ports, command lines, partition names, or other unbounded payload-derived values.
Index metrics SHALL include entries and bytes per shard, budget refusals, evictions, history evictions inside the horizon, ownership consumer lag, shard state (`warming`, `ready`, `standby`), rebuild duration, ambiguous lookups, and late conflicts (a lease applied that overlaps another owner's lease on the same key). Enrichment metrics SHALL include flows by outcome and strategy, hold buffer depth and overflow, decision state count and bytes, early finalizations per shard, applied and evidence-only updates, and lookup latency per batch. Connection summary metrics SHALL include rows per interval, merged rows by aggregation level, intervals that reached the overflow level, and summary consumer lag.

#### Scenario: Index falls behind
- **GIVEN** ownership events arrive faster than a shard applies them
- **WHEN** health is reported
- **THEN** the ownership consumer lag metric rises for that shard
- **AND** the metric labels identify the shard ordinal only

## MODIFIED Requirements

### Requirement: Attribution Requires StarRocks
When StarRocks is not configured, flow process attribution SHALL be disabled: ownership events MUST NOT be published or stored, the ownership index MUST NOT start, and the attribution health surface MUST report that StarRocks is required.

#### Scenario: Deployment without StarRocks
- **GIVEN** a deployment with no StarRocks warehouse configured
- **WHEN** an agent delivers socket ownership events
- **THEN** core does not publish or persist them anywhere
- **AND** the attribution health surface reports `attribution_disabled: starrocks_required`

### Requirement: Correlation Is Protocol-Aware And Exact-First
Flow attribution SHALL preserve every deployed protocol- and topology-aware candidate family, within the flow's partition and the lookup's time tolerance, as an ordered sequence of key lookups with deterministic precedence. An exact match MUST rank ahead of every fallback. A `connected` lease whose remote endpoint equals the flow's other side, an exact peer entry on the flow side's full 5-tuple including its local port, or an ICMP or ICMPv6 peer entry on endpoint addresses without port equality is exact. A `bound` lease (listener, expanded wildcard listener, or unconnected UDP socket) on the flow side's endpoint MAY match TCP or UDP at the listener rank. A relaxed UDP peer entry MAY match the same endpoint IP roles and remote service port while allowing the local ephemeral port to be zero or to differ from the exporter-observed port. Lower-ranked node-SNAT peer entries MAY map a registered agent node IP to the attributed socket while preserving the remote endpoint and service port. A public endpoint MAY map a known VIP, protocol and port to backend endpoints that are then looked up. Public-endpoint candidates MUST rank below exact, listener or relaxed, and node-SNAT candidates, and their Gateway, LoadBalancer/ExternalIP, and other exposure classes MUST keep that relative order. No fallback candidate may displace an eligible exact candidate, whether it is found on ingest, through a public endpoint, or by a late stamp. Across the two sides of a flow, the lower rank SHALL win, and on a tie the source side SHALL win.

#### Scenario: Exact TCP tuple is correlated
- **GIVEN** a `connected` TCP lease for 192.0.2.20:40001 whose remote is 198.51.100.9:443
- **WHEN** a flow from 192.0.2.20:40001 to 198.51.100.9:443 in the same partition is attributed
- **THEN** the lookup selects that lease
- **AND** it records the match strategy as exact

#### Scenario: Coalesced listener matches a local service endpoint
- **GIVEN** a `bound` TCP or UDP lease on a local endpoint
- **WHEN** a flow's side matches its partition, protocol and endpoint within the time tolerance
- **THEN** the lookup may select the listener lease only when no exact candidate ranks ahead of it
- **AND** it records the match strategy as wildcard listener

#### Scenario: Exact UDP candidate outranks relaxed candidates
- **GIVEN** one exact UDP candidate and one or more relaxed UDP candidates are eligible for the same flow
- **WHEN** the candidates are ranked
- **THEN** the exact candidate is selected
- **AND** no relaxed candidate may displace it because its lease is newer or closer in time

#### Scenario: UDP client observation uses the relaxed service-port match
- **GIVEN** a UDP lease has a zero coalesced local port, or a non-zero local ephemeral port that differs from the exporter-observed port
- **AND** no exact UDP candidate exists
- **WHEN** a UDP flow matches the same partition, protocol, endpoint IP roles, remote service port, and time tolerance
- **THEN** the flow may be attributed from that relaxed candidate
- **AND** the match strategy is recorded as relaxed UDP rather than exact

#### Scenario: Relaxed UDP candidate is ambiguous
- **GIVEN** no exact candidate exists and more than one lease satisfies the constrained relaxed UDP match for one flow
- **WHEN** the candidates are evaluated
- **THEN** the ambiguous-candidate outcome is incremented
- **AND** any resulting match evidence MUST identify the relaxed ambiguity rather than presenting the result as exact attribution

#### Scenario: ICMP exporter pseudo-ports differ
- **GIVEN** an ICMP or ICMPv6 peer entry and a flow share a partition, endpoint IPs, protocol, and time tolerance
- **WHEN** their port or type/code representations differ
- **THEN** the candidate is evaluated without requiring port equality

#### Scenario: Node-SNAT maps a pod-local attribution to its agent node
- **GIVEN** a node-SNAT peer entry exists for the agent's registered node IP and the flow's remote endpoint and service port
- **WHEN** a flow uses that node IP after SNAT within the partition and time tolerance
- **THEN** the lookup may select the node-SNAT candidate only after higher-ranked candidates
- **AND** it records the match strategy as node SNAT

#### Scenario: Public endpoint maps a VIP to a backend socket
- **GIVEN** a known public endpoint maps a VIP, protocol, and port to a backend endpoint that has a lease
- **WHEN** a flow uses that VIP within the partition and time tolerance
- **THEN** the lookup may select the public-endpoint candidate only after higher-ranked candidates
- **AND** it records the applicable public-endpoint strategy

#### Scenario: Exact local candidate outranks a Gateway public endpoint
- **GIVEN** an exact candidate and a Gateway public-endpoint candidate are both eligible for one flow
- **WHEN** the candidates are ranked
- **THEN** the exact candidate is selected even though the public endpoint's raw exposure rank is zero
- **AND** Gateway still ranks ahead of LoadBalancer, ExternalIP, and other candidates when public endpoints are compared with each other

#### Scenario: Both sides match at the same rank
- **GIVEN** both endpoints of a flow have listener-rank candidates and neither side has a better one
- **WHEN** the flow is attributed
- **THEN** the source side's owner is written

### Requirement: Correlation Exposes Topology And Match Outcomes
The flow attribution stage SHALL publish one bounded diagnostic per reporting interval on the flow-attribution metric subject, counting flows by exactly the outcomes `attributed`, `held`, `late_stamped`, `unmonitored`, `no_owner`, `ambiguous`, `index_warming`, and `error`, and SHALL report `no_producer` when no ownership events arrived in the interval and `no_flows` when no flows reached the processor. An interval whose readings are missing SHALL omit that diagnostic rather than guess. Each interval SHALL also publish attributed counts for the exact, listener-or-relaxed, node-SNAT, and public-endpoint strategies. Exported metric labels MUST NOT include agent identifiers, process identifiers, IP addresses, ports, command lines, partition names, or other unbounded payload-derived values. Sampled diagnostic logs MAY include bounded agent and partition context.

#### Scenario: Sampled flow and attribution sets have no topology overlap
- **GIVEN** ownership leases exist for a netprobe host
- **AND** no flow in the interval has that host's addresses on either side
- **WHEN** the interval's diagnostic is published
- **THEN** those flows count as `unmonitored`
- **AND** the outcome is not reported as an attribution failure

#### Scenario: Candidates are considered but no row is stamped
- **GIVEN** a flow side is a monitored address
- **WHEN** no lease matches after the hold and the late window
- **THEN** the flow counts as `no_owner`
- **AND** an operator can tell this apart from an index that was warming or a stage that did not run

#### Scenario: A row is stamped with a classified strategy
- **GIVEN** an eligible exact or fallback candidate exists
- **WHEN** the flow is written as `attributed_flow`
- **THEN** the `attributed` count increments
- **AND** the corresponding exact or fallback strategy count increments

### Requirement: Flow Attribution Admission Is Bounded Isolated And Commit-Confirmed
Core SHALL execute flow-attribution (socket ownership) admission through a dedicated supervised admission lane rather than inside the shared `StatusHandler` mailbox. The lane MUST be independent of retained plugin-result admission, retain the original synchronous caller reference, and reply only after JetStream has acknowledged every message of the complete unit or the unit has failed. It MUST bound concurrency, total admitted item count, total retained encoded payload bytes, per-agent admitted items, queue wait, and worker runtime; item and byte totals SHALL include queued and in-flight work. The default SHALL be exactly one worker, 16 total admitted items, 64 MiB of total retained payload, four admitted items per agent, a two-second maximum queue wait, and a 20-second worker timeout. Deployments MAY configure different positive concurrency, item, byte, per-agent, queue-wait, and worker-timeout bounds. Queue wait MUST NOT exceed two seconds, worker runtime MUST NOT exceed 20 seconds, and their sum plus three seconds MUST NOT exceed the gateway core-call deadline. That gateway deadline MUST NOT exceed 25 seconds while the agent flow RPC deadline remains 30 seconds. Retained-byte admission MUST account for the encoded payload plus fixed envelope overhead. The lane SHALL expose queued and in-flight depth and bytes, queue wait, run duration, admission rejection, timeout, task exit, and completion-outcome telemetry. A producer batch of at most 4,096 events and 6 MiB SHALL remain one logical acknowledgement unit and MUST NOT be acknowledged as independently committed sub-batches.

#### Scenario: Accepted batch replies only after commit
- **GIVEN** a valid ownership batch is admitted within every item, byte, and per-agent bound
- **WHEN** its worker publishes the complete unit successfully
- **THEN** the lane replies to the original caller only after JetStream acknowledges every message of the unit
- **AND** the reply transfers retry ownership for that complete unit

#### Scenario: Saturated flow lane does not block unrelated status work
- **GIVEN** the flow-attribution lane is at its concurrency or admitted-capacity limit
- **WHEN** unrelated status work or retained plugin-result work reaches core
- **THEN** the shared status mailbox remains available to classify that work
- **AND** flow-attribution saturation does not consume the retained plugin-result lane's item, byte, or worker budget

#### Scenario: Admission exceeds a mandatory bound
- **GIVEN** accepting a flow-attribution batch would exceed the lane's total item, total retained-byte, or per-agent admitted limit across queued and in-flight work
- **WHEN** core evaluates admission
- **THEN** it rejects the batch with an explicit admission error
- **AND** it performs no inline flow-attribution publish work in `StatusHandler`

#### Scenario: Lane telemetry accounts for admitted and rejected work
- **GIVEN** flow-attribution batches are admitted, executed, completed, timed out, or rejected
- **WHEN** the lane reports its operational state
- **THEN** its telemetry separately accounts for queued and in-flight depth and retained encoded bytes
- **AND** it records queue wait, worker duration, and the applicable completion or rejection outcome

#### Scenario: Admitted work does not reach durable completion
- **GIVEN** a flow-attribution batch has been admitted
- **WHEN** it exceeds its queue-wait or worker deadline, its task exits, or a publish is not acknowledged
- **THEN** the lane replies to the original caller with the corresponding explicit error
- **AND** it does not report the batch as committed
- **AND** retrying the complete unit remains safe because applying a repeated lease event leaves the index unchanged

#### Scenario: Concurrent workers are configured
- **GIVEN** a deployment configures more than one flow-attribution worker
- **WHEN** batches from many agents are admitted
- **THEN** they are published concurrently within the configured bounds
- **AND** each batch is still acknowledged only as one complete unit

#### Scenario: Flow attribution cast follows the bounded path
- **GIVEN** legacy compatibility delivers flow attribution without a caller reference
- **WHEN** core accepts the cast
- **THEN** it routes the work through the same bounded flow-attribution lane
- **AND** it MUST NOT execute the publish inline in a shared mailbox
- **AND** no production agent-retained producer may use the cast as a commit acknowledgement

#### Scenario: One producer batch remains one acknowledgement unit
- **GIVEN** a valid producer batch contains no more than 4,096 events and 6 MiB of encoded payload
- **WHEN** core admits that batch
- **THEN** the lane treats the complete batch as one logical acknowledgement unit
- **AND** it does not acknowledge a published prefix while the remainder is unpublished

### Requirement: Post-Rollout Verification Proves The Committed Artifact Chain
Release and deployment verification SHALL start after rollout completion and SHALL verify the exact deployed netprobe version and artifact before applying a new stimulus. End-to-end success MUST be established from post-rollout artifacts: a real TCP connection, TCP producer-stage evidence, an ownership lease for the stimulus socket in the index and in `flow_ownership_leases`, a sampled flow with an eligible endpoint and time overlap, and the resulting `attributed_flow` row with the expected process context. Process health, probe-attach logs, gateway acknowledgements, index or enrichment health metrics, or pre-rollout rows MUST NOT be accepted as substitutes for the final database artifact.

#### Scenario: Verification rejects a stale deployed netprobe artifact
- **GIVEN** a candidate rollout is reported complete
- **WHEN** the target host's running netprobe version or artifact identity does not match the candidate release
- **THEN** verification fails before interpreting protocol or attribution results
- **AND** rows produced by the stale artifact do not satisfy the candidate release gate

#### Scenario: Netprobe attribution change advances the native add-on artifact
- **GIVEN** a netprobe source change affects flow-attribution behavior
- **WHEN** the candidate native add-on artifact is prepared for rollout
- **THEN** the netprobe add-on manifest version and Bazel `NETPROBE_VERSION` advance together
- **AND** the bundle, version-bump, and native-add-on build gates succeed before that artifact is used for end-to-end verification

#### Scenario: Post-rollout TCP flow is attributed end to end
- **GIVEN** rollout completion and the expected netprobe artifact have been verified on the target host
- **AND** the selected connection path traverses a sampled export path visible to ServiceRadar
- **WHEN** a process completes a real TCP connection after rollout
- **THEN** TCP lifecycle evidence for that stimulus appears at the producer stages
- **AND** a `flow_ownership_leases` row newer than the stimulus contains the expected key and process owner
- **AND** a sampled flow newer than the stimulus contains the matching endpoint and eligible time overlap
- **AND** that flow row is committed with `event_type = "attributed_flow"` and the expected agent and process context, written on ingest or by a late stamp

#### Scenario: Delivery control makes a missing TCP row meaningful
- **GIVEN** a controlled TCP stimulus has completed after rollout
- **WHEN** no ownership lease row for the stimulus appears
- **THEN** verification MUST require a post-stimulus positive delivery control from the same netprobe-to-core path before classifying TCP production as failed
- **AND** absence of that control is reported as an inconclusive delivery state rather than proof of a TCP producer defect

#### Scenario: Export topology cannot observe the target host
- **GIVEN** post-rollout ownership leases exist for the target host
- **WHEN** no sampled flow involving that host's addresses exists within the eligible time tolerance
- **THEN** end-to-end verification fails with `unmonitored`
- **AND** it does not classify the missing attributed row as a TCP producer or index regression

#### Scenario: Correlator completion does not prove an attributed artifact
- **GIVEN** the index and the attribution stage, which replace the correlator, report healthy metrics
- **WHEN** no exact post-stimulus `ocsf_network_activity` row is committed as `attributed_flow`
- **THEN** end-to-end verification remains failed

## REMOVED Requirements

### Requirement: Attribution Observations Flow Through JetStream Into StarRocks
**Reason**: Periodic socket sightings are replaced by ownership leases. The `flows.attribution.observations` subject, the `FlowAttributionObservations` processor and the `flow_process_attribution_observations` table are deleted.
**Migration**: Straight switch. Ownership leases travel on `flows.ownership.<bucket>` (see *Socket Ownership Changes Flow Through JetStream*), and history is kept in `flow_ownership_leases`. Nothing is migrated: the observation window is ephemeral.

### Requirement: Observation Storage Has No Row-Level Churn
**Reason**: The observation table is dropped. Its append-only, partition-expiry discipline carries over to the lease history table.
**Migration**: See *Ownership Lease History Is Append-Only*. The `attribution` retention dataset now governs `flow_ownership_leases`.

### Requirement: Correlation Runs In The Warehouse
**Reason**: The periodic in-warehouse join has a fixed throughput ceiling (about 42 flows/s at the current batch limit and interval), and its cost grows with flows times observations. Attribution becomes a key lookup on ingest.
**Migration**: See *Flows Are Attributed On Ingest By Key Lookup* and *Late Binding Is Bounded And Never Rescans Flows*. `FlowAttribution.Correlator`, `FlowAttribution.Correlation` and the correlator kill switch are deleted. `events.flow.attribution` remains, for late stamps only.

### Requirement: Correlator Health Is Observable
**Reason**: There is no correlator pass to measure.
**Migration**: See *Ownership Index And Enrichment Health Is Observable*. `PassMetrics` is deleted.
