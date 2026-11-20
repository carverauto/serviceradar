## Decisions

### Bounded publication before wire migration

Each publisher worker has configurable pending-count and encoded-byte limits.
The first implementation uses `output.nats_max_inflight` (default 32) and
`output.nats_max_inflight_bytes` (default 8 MiB); a window of one is the serial
comparator. With multiple `nats_threads`, these bounds apply per worker.
Document bridge/staging overhead separately rather than claiming these bound
the entire existing upstream queue.

Retries retain payload, message ID, route and admission slot. Preserve existing
ACK-ambiguity deadlines relative to the stream duplicate window and permanent/
certificate error behavior. A record that cannot fit fails explicitly instead
of waiting forever. Admission and completion do not promise source ordering.

A persistent bounded bridge replaces per-record blocking dispatch. Never block
the async NATS runtime on synchronous receive. On source closure, drain admitted work under the configured retry policy.
ACK-ambiguous retries remain bounded; explicitly unlimited pre-store reconnect
policy does not imply a finite global shutdown deadline. Verify actual blocked
bridge and disconnected output behavior, not just counter arithmetic.

### Shared native Zen

Extract a project-owned Rust normalization library. Construct native Variables
directly and keep them native across ordered rules; share unchanged strings.
Preserve recursive overlays: explicit null remains, nested objects merge,
arrays/scalars replace. Zen's built-in merge differs and is not a substitute.

Keep Rc/RefCell values on bounded worker-local executors. Compile outside the
record path. Existing HipStr ownership supports ordinary shared buffers; a
NIC-lease string extension is a separately measured upstreamable change.
Conformance must cover numeric conversion boundaries, error behavior, aliases,
custom JDM and JavaScript nodes before removing intermediate conversions.

### Immutable rules through the rule store

Publish a self-versioned bundle with effective scope, ordered keys/content and
digest. Validate and compile the entire candidate before activation. If a
bundle exceeds configured KV limits, use immutable documents with a manifest
pinning content digests, never mutable unversioned references.

Collectors read rules from the rule store and over the transport defined by
`collector-rule-distribution`, with existing authenticated identity. Watch
carries bytes without replay cursors: supervise reconnection and reconcile
through Get. No record-path RPC and no watch per sending host. Reconcile the
current agent/stream/subject scope differences in compiler/conformance work.

Each batch uses one ruleset version. Invalid updates retain last-known-good
and expose stale/error status. Explicit empty snapshots are valid. A collector
never refuses syslog for want of a ruleset: until its first validated snapshot
it publishes a schema-header batch without `Sr-Ruleset-Id` on
`logs.normalized.<kind>`, which EventWriter stores with built-in mapping, and it
normalizes from the next record once a snapshot is active (see
`collector-rule-distribution`). A persisted snapshot must pass the same validation. Preserve current per-record failure semantics
until shared conformance establishes the exact behavior.

### Binary contract

Start with OTLP ExportLogsServiceRequest. The proposed transport headers are:

| Header | Contract |
| --- | --- |
| Content-Type | application/x-protobuf |
| Sr-Log-Schema | otlp-normalized-v1 |
| Sr-Normalization-Version | 1 for the shared normalization contract |
| Sr-Ruleset-Id | Validated effective snapshot content digest; present when rules were applied, absent on a built-in-mapping pass-through batch |
| Sr-Collector-Id | Existing authenticated collector component identity |
| Sr-Routing-Epoch | Immutable routing epoch; 0 for unsharded binary mode |
| Nats-Msg-Id | Stable batch identity retained across retries |

Use reserved OTLP attributes `serviceradar.record_id` and
`serviceradar.source_id` for stable per-record identity and trusted source
routing identity. User fields cannot overwrite these attributes. Headers and
identities must be verified against publisher grants and the authorized binary
route; a header string alone does not authenticate a collector. Existing
OTLP time/trace/scope fields retain their normal meanings.

Bound encoded bytes, records and age; include headers in negotiated NATS
payload sizing. Do not mix shard routes or ruleset versions within a batch.
Assign IDs before the first publish and retain exact retry bytes. Budget
expanded records in consumers, not only NATS-message counts.

Complete parity for source_ip, observed_timestamp, trace_flags, event_name,
scope attributes, syslog fallback fields, raw-message policy and unknown
custom rule output. Existing OTLP decoding alone does not establish parity.
Generated owned String fields can copy; borrowed encoding is a measured option.

### Trust, persistence and replay

Only authenticated collector traffic on the approved binary route may assert
completed normalization. User-supplied log fields cannot skip Zen/redaction.
Replay uses the original normalized result and version; explicit reprocessing
is a separate operation. Redact protected content before durable publication
while retaining downstream enforcement.

ACK only after persistence succeeds in the selected backend: StarRocks when
enabled, otherwise CNPG. Preserve current side effects and stable IDs. Do not
claim exactly-once behavior from JetStream message deduplication. Before enabling
multi-record batches, define partial-failure recovery so replay does not create
duplicate rows or repeat non-idempotent effects already completed.

### Rollout and evidence

Ship dual-format readers and parity checks, opt in collectors, drain retained
legacy messages, then consider retiring legacy support. Coordinate subject,
ACL and stream ownership with partition-log-ingestion.

Measure synthetic open-loop durable searchable throughput, tail latency, CPU,
allocations, copied bytes and memory. Compare equivalent rules and durability.
Rust consumers and warehouse CSV must win that comparison before replacing
existing paths. No speed ranking or end-to-end zero-copy claim is approved.
