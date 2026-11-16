## JetStream model

A stream is the sharding unit. Each replicated stream has one leader and its
own replicated state. Consumer scaling increases processing capacity; stream
sharding distributes ingestion leadership. Replication provides resilience and
costs bandwidth/storage; it is not write partitioning.

A synthetic four-shard layout is:

| Publish subject | Stream | Persistence durable |
| --- | --- | --- |
| log_ingest.v1.e1.s0 | LOG_INGEST_E1_S0 | event-writer |
| log_ingest.v1.e1.s1 | LOG_INGEST_E1_S1 | event-writer |
| log_ingest.v1.e1.s2 | LOG_INGEST_E1_S2 | event-writer |
| log_ingest.v1.e1.s3 | LOG_INGEST_E1_S3 | event-writer |

These are illustrative names for a new contract, not a live topology. Each
stream owns its exact shard subject. The existing `events` stream owns
`logs.>`; `logs.shard.*` would overlap it and is not an acceptable migration.
Validate all actual subject ownership, including broader wildcard streams,
before provisioning. The new prefix requires explicit permissions and routing.

NATS also supports deterministic server-side subject mapping with
`{{partition(n, wildcard_index)}}`. That hashes a subject token; it does not
create streams, provision consumers or inspect every record inside a batch.
Our first implementation routes in the collector so it can select a shard
before batch construction without exposing host identities in subject names.
Do not mix the server's hash function with a different client hash function.

## Routing and ordering

A centrally owned routing snapshot contains epoch, shard count, exact subjects,
stream names and a digest. For the first algorithm, hash the canonical
source-identity bytes with SHA-256, interpret the first eight digest bytes as
an unsigned big-endian integer, and take modulo shard count. Freeze synthetic
cross-language vectors before implementation.

Use trusted device/source identity when available. Otherwise derive identity
from a configured ingress scope and observed source address, excluding ephemeral
source ports; canonicalization and length-prefixed field encoding must be
specified with fixtures. Do not trust a claimed syslog hostname to establish
identity. Resolve NAT/multiple-device ambiguity as a routing limitation.

Route records before batching. Every batch contains one epoch, shard, schema
and ruleset version. Retries keep the original subject, stream, message ID and
bytes after a routing update. Validate expected stream ownership on publication.
A failed shard does not silently reroute into another shard or the legacy stream.

Source affinity is not a strict processing-order guarantee: concurrent
collectors, pipelined ACKs, shared workers and redeliveries can reorder records.
This log pipeline guarantees stable identity and recorded event/observed time,
not global or exactly-once processing order. Any future strict per-source
ordering mode needs serialized source ownership and a migration barrier.
Hot sources can still overload a shard; expose skew rather than silently
splitting a source and claiming ordering.

## Provisioning and consumption

One topology reconciler owns desired streams and consumers. Collectors publish
to provisioned routes; they must not race to mutate the entire shard topology.
Preserve existing identity/certificate authorization and include the new routes
in grants and management views.

Use file-backed streams with configured replication, explicit retention/age
and capacity policy. Default to the installation's durability policy, never
reduce replicas to win a benchmark. Compute aggregate logical storage budgets
across shards and separately show replicated physical cost. Do not assign every
shard the previous whole-stream budget. Capacity rejection/retention expiry
must be observable; sharding cannot guarantee indefinite buffering.

For persistence, replicas share one named durable pull consumer per stream.
Each durable's explicit ACK advances only after successful persistence under
accelerate-log-ingestion's replay contract. Independent durable names receive
independent copies and are reserved for distinct purposes. Do not republish
normalized messages into one central stream that recreates the bottleneck.

Bound fetch bytes/messages, expanded records, outstanding ACKs and warehouse
load concurrency. Ensure deployment replica limits and per-worker admission
fit a stated aggregate storage budget. Keep fair progress across subscribed
shards so one hot shard does not starve another.

## Placement and scale

Several stream leaders may live on the same server. Replication factor three
on a three-server cluster places every shard's replicas on all three servers;
adding shards alone does not distribute that disk footprint over more hosts.
Measure leader placement, per-node disk/CPU, network replication, ACK latency,
consumer backlog and warehouse limits. Add servers and configure placement
when those resources require it. Shard count is bounded configuration, not host
count, and a high shard count has control/state overhead.

## Migration and resharding

1. Provision disjoint new streams, budgets, grants, consumer routes and metrics.
2. Deploy consumers supporting both legacy and new routes; verify synthetic
   field and persistence parity before changing real producers.
3. Publish a validated routing epoch to collectors. New batches use it;
   already-admitted batches finish on their original epoch.
4. Keep old consumers/streams until producers have stopped using them and
   pending data has drained or an explicit retention policy resolves it.
5. Rollback routes new batches to a previous valid layout while both layouts
   continue draining. Never purge a stream as an automatic rollback step.

Changing shard count creates a new epoch; changing modulo in place is forbidden.
Collectors can transition at different times. Stable per-record IDs support
replay accounting across epochs; JetStream's stream-local dedup window cannot
provide cross-stream exactly-once behavior. Strict cross-epoch source ordering
is not promised. Do not dual-publish every record as a migration shortcut.

## Evidence gates

Compare one stream and multiple streams on the same payloads, rules, replica
count, total retention budget and warehouse workload. Separate receive,
publish-ACKed, persisted and searchable rates. Sharding is enabled when results
justify it; a faster collector alone does not prove a NATS bottleneck.

## References

- [JetStream clustering](https://docs.nats.io/learn/topologies/jetstream-in-a-cluster)
- [Subject partition mapping](https://docs.nats.io/learn/core-nats/subject-mapping)
- [Shared pull consumption](https://docs.nats.io/learn/jetstream/pull-consumers)
