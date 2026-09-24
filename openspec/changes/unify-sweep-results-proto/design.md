# Design: Durable extensible edge producer data plane

## Context

The live sweep path is:

```text
Go sweep summary -> whole-run JSON -> ResultsChunk -> StreamStatus
  -> agent-gateway -> asynchronous ERTS cast -> core ResultsRouter
  -> JSON decode -> sweep/device/OCSF writes
```

The agent also parses that sweep JSON back into generic maps and creates a
second protobuf `MetricBatch`. Scheduled MTR similarly sends full JSON on the
direct results path and a separate scalar `MetricBatch`. The metric copy is
published to JetStream, but it is not the complete MTR trace and does not write
the MTR trace/hop tables.

The same ownership problem exists outside sweep. Wasm `submit_result` and
`emit_telemetry`, native add-on `StreamTelemetry`, the specialized native OTLP
relay, and embedded sync integrations each have separate queueing, payload,
retry, and acknowledgement code. Several paths drain an in-memory queue before
`StreamStatus` succeeds; Wasm metric output currently wraps protobuf in base64
inside JSON and the agent reverses that representation before forwarding it.
Armis inbound discovery already fetches and emits bounded API pages, but those
pages are converted to maps, repeatedly JSON-sized/encoded, routed through ERTS,
decoded again in Core, and coalesced in memory before inventory projection.

This is not merely a serialization problem:

- the agent deep-copies/materializes an entire scan before delivery;
- a one-million-host payload exceeds the 64 MiB `StreamStatus` window;
- the gateway can acknowledge before durable storage and can drop from its
  volatile fallback queue;
- Core NATS publish does not provide a JetStream PubAck;
- one core results router serializes high-volume work;
- generic metric expansion can create tens of rows per host and hundreds per
  trace; and
- replay is not idempotent across sweep, OCSF, execution, and MTR projections.

## Active milestone scope and review contract

Task 0.12, the first green vertical slice, is the active milestone. Until it is
green, this section governs what may BLOCK its implementation PRs and what must
be deferred. It exists because independently expanding proof surfaces has no
natural stopping point and had displaced the first composed runtime result.

### Slice authority

The authority is the six finite acceptance groups in task 0.12, exercised with
one committed BULK `SweepObservationBatchV1` fixture on one valid durable route.
Task 0.12 coordinates the composed acceptance target; tasks 2-5 retain semantic
ownership of their seams. Work is in scope only when it is necessary to make
that real path execute, satisfy one of those explicitly listed controls, or
prevent the target from reporting a false success. Existing broader tasks
remain authoritative for later work; they do not silently become slice
prerequisites. Normative requirements applicable to groups A-F or to a concrete
V2 boundary-safety finding, plus existing required checks, remain binding; they
do not create a seventh acceptance group or require completion of an owning
parent task.

### A finding blocks only in these classes

- **V1 -- CLOSURE FAILURE:** it can make an observation or control explicitly
  listed in task 0.12 groups A-F false.
- **V2 -- BOUNDARY SAFETY:** it demonstrates a concrete regression introduced
  by the active diff, or a data-loss path, authentication/authority bypass,
  crash, or unbounded work reachable through the declared v1 boundary. The
  positive fixture need not contain the triggering value. A bound finding SHALL
  name the normative grant, size, or work limit and show that work occurs before
  its gate. Task 3.3's restart-overlap and post-handoff races are V2 findings and
  remain mandatory closure controls.
- **V3 -- FALSE OR ABSENT GATE:** the composed target is not in required CI or
  Bazel, cannot execute its claimed real NATS/CNPG path, or an assertion is
  vacuous/self-derived such that a required closure observation may be false
  while the target stays green.
- **V4 -- REQUIRED AMBIGUITY:** an externally observable interoperability or
  safety choice materially changes a task-0.12 result or V2 verdict, and the
  existing normative sources are absent or conflict. The finding SHALL cite the
  missing or conflicting clauses. A reversible implementation-local choice is
  not V4. The ambiguity blocks only that decision; it does not authorize
  completing adjacent future cases.

A blocking review finding SHALL name V1-V4 and the affected task-0.12 group or
active-path safety invariant. It SHALL include a concrete reproducer or
production-path trace, or a static demonstration that a required gate is
absent/fail-open or a bound runs after the work it is meant to constrain.
For V4, the cited absent or conflicting normative clauses are the sufficient
static demonstration. Cross-runtime disagreement and a surviving mutation are
evidence only when they establish one of these classes.

An exact-head re-review covers unresolved findings from the prior review, the
fixing diff, and concrete regressions in the affected surface. It SHALL NOT
restart unrelated full-tree proof discovery without a concrete V1-V4 reason.

### Findings that do not block this milestone

- additional mutation-score completion, proof axes, fixtures, or all-pairs
  matrices with no V1-V4 behavior;
- terminology, historical narration, comment completeness, API aesthetics, or
  equivalent rewrites; a contradiction or overstatement blocks only when the
  reviewer demonstrates that it establishes V1-V4;
- future producer types, traffic classes, route layouts, output contracts, or
  inputs proven unreachable through the declared v1 boundary rather than merely
  absent from the positive fixture;
- MTR, recovery, generalized DLQ/redrive, fleet-capacity tuning, benchmarks,
  dashboards, rollout, soak, and final ABI/archive completeness; and
- completing an entire parent task when task 0.12 consumes only one of its
  narrow production seams.

An actionable non-blocking defect SHOULD be recorded once in an existing named
task or a separate issue and, when recorded, linked once in the implementation
PR's consolidated deferred summary. Logging or listing it is not an approval
prerequisite and its absence cannot delay approval or start another review
round. Recording it SHALL NOT append implementation to the active PR or demand
another mutation round. Wording-only cleanup is batched after the slice unless
it meets a blocking class above.

### Scope amendments

Implementation and review agents may propose changing task 0.12, but they may
not promote their proposal into the active milestone. A scope change requires
explicit maintainer approval in a separate docs-only amendment. An active
implementation PR cannot redefine its own acceptance boundary.

### Stopping rule

Review stops expanding when no V1-V4 finding remains. Task 0.12 closes when its
required composed target passes all six groups on real NATS and scratch CNPG in
the required `BazelCI` check. Groups A-F are the complete acceptance matrix; a
reviewer does not add a seventh group without the scope-amendment process above.
Closure does not check broader parent tasks, complete the ABI freeze, authorize
production rollout, or waive deferred work. It ends this scope freeze and
permits the next milestone to be chosen explicitly.

## Goals

- Bound memory by active scan window plus in-flight/spooled bytes, not fleet
  size or completed scan size.
- Encode each canonical domain body once at the producer adapter, wrap it in one
  `EdgeRecordV1` encode at the agent sink, pass those bytes through the gateway,
  and decode once in each downstream consumer.
- Acknowledge the agent only after the observation is durably stored in
  JetStream.
- Preserve complete sweep, execution, scanner, banner, and MTR trace fidelity.
- Support at-least-once delivery with application-level idempotency.
- Make overload explicit through backpressure, spool pressure, stream limits,
  and incomplete-execution state; never silently report success after a drop.
- Scale consumption horizontally with fixed logical partitions, bounded shared
  pull consumers, and database-enforced concurrency correctness.
- Keep raw history bounded while preserving current state and useful rollups.
- Make the crash-safe spool, flow control, gateway PubAck, fairness, and
  provenance machinery reusable by built-in collectors, Wasm plugins, native
  add-ons, and agent-side integration producers without exposing transport or
  broker authority to those producers.
- Allow approved package-defined outputs through a bounded contract/processor
  registry while keeping platform schemas, routing, capacity, and database
  mutation authority under platform control.

## Non-Goals

- Replacing JSON in low-volume commands, configuration, or administrative APIs.
- Turning the record data plane into a universal workflow, command, media,
  tunnel, or artifact-byte transport.
- Letting a plugin/add-on select a NATS subject, physical stream, traffic class,
  database table/DDL, or executable Core processor.
- Forcing cluster-local producers to hairpin through an agent/gateway; they may
  use the same authoritative record/projector contract through a governed direct
  JetStream publisher or transactional outbox.
- Treating JetStream Object Store as a telemetry lake.
- Claiming literal end-to-end zero-copy across protobuf, gRPC/TLS, BEAM, NATS,
  replicas, and PostgreSQL WAL.
- Selecting a new database before the canonical workload is benchmarked against
  the existing CNPG/Timescale path and candidate alternatives.

## Workload Model

The architecture is sized around completed observations, not just agent count.
The first benchmark profile is one million targets, ICMP plus ten TCP ports,
hourly, with results draining in a six-minute burst.

Order-of-magnitude estimates to validate with fixtures:

| Representation | Approximate one-million-host size | Six-minute drain |
|---|---:|---:|
| Current ICMP + ten-port JSON | 0.8-0.9 GB | 2-3 MB/s |
| Straightforward host protobuf | 150-220 MB | 0.4-0.7 MB/s |
| Compact batch-oriented protobuf | 80-140 MB | 0.2-0.4 MB/s |
| Duplicate per-host generic MetricBatch | 3.5-5.5 GB | 10-16 MB/s |
| Full twenty-hop MTR protobuf for every host | 1.5-4 GB | 4-12 MB/s |
| MTR flattened into generic metric points | 40-70 GB | 110-200 MB/s |

The average rate of one million hosts per hour is only 278 hosts/second. The
danger is synchronized bursts, whole-run memory, duplicate row expansion,
per-hop multiplication, hot execution counters, and database/index/WAL cost.
The design therefore removes whole-run and duplicate representations before
micro-optimizing protobuf allocation.

Universal hourly MTR is not a reasonable default. At twenty hops it produces
twenty-one persisted rows per trace and can require tens of millions of probes
per run. The scheduler must budget and shard MTR independently from sweep host
summaries.

ServiceRadar installations are single-customer security and capacity domains;
the SaaS control plane provisions customers in separate clusters. This data plane
therefore does not add per-tenant NATS accounts, database schemas, capacity cells,
or fairness. Inside one installation, fairness and identity are hierarchical by
network/site partition, agent, execution, and traffic class. `network_scope_id`
is an explicit site/address-space namespace so overlapping RFC1918 networks do
not collide; it is not a SaaS tenant identifier.

## Decision 1: Layer the transport and durability responsibilities

```text
agent/scanner/plugin/add-on/integration producers
  -> agent-owned producer API
  -> crash-safe agent spool
  -> bidirectional mTLS gRPC record stream
  -> authenticated stateless gateway
  -> JetStream publish request + PubAck
  -> partitioned pull consumers
  -> idempotent bounded database transactions
```

- gRPC provides edge authentication, connection management, streaming flow
  control, and cumulative application acknowledgements.
- The gateway is the edge trust boundary and sole publisher for
  agent-originated durable records. It does not own durable delivery state.
- JetStream is the durable commit, replay, fan-out, and backlog boundary.
- ERTS/direct core calls remain for control, configuration, commands, heartbeat,
  and small status. They are not a bulk persistence acknowledgement.
- The agent spool owns unacknowledged data. If JetStream is unavailable or full,
  the gateway withholds ACKs and the agent retains the frames.
- A local producer receives success only after the agent owns the exact record
  durably. Gateway acceptance remains a separate later watermark requiring
  JetStream PubAck. This transfers retry ownership once instead of requiring
  every Wasm/native producer to implement the full edge transport.

This avoids a gateway persistent-volume requirement and keeps gateways
replaceable. A future gateway disk spool may be proposed for sites that must
accept data while every agent is storage-constrained, but it is not part of the
v1 correctness chain.

Cluster-local producers do not impersonate agents or hairpin through this edge
hop. A governed direct publisher uses its own attested service identity,
contract-scoped capability, the same registry/envelope rules, and an
authoritative JetStream PubAck. A transactional outbox is allowed only when the
record's system of record is the same operational transaction; metrics and
telemetry remain JetStream-first and cannot use an outbox as a database-first
ingestion exception.

## Decision 2: Use a producer-neutral transport frame with typed contracts

The producer adapter encodes its canonical domain body once. The agent-owned
sink validates that body, constructs the complete semantic `EdgeRecordV1`,
deterministically encodes it once, and fsyncs those exact bytes with a small
`EdgeDeliveryFrameV1` containing spool coordinates and delivery-only authority.
The gRPC lane decodes only that delivery wrapper. The gateway verifies its
checksum, retains the original `record_bytes`, bounded-decodes `EdgeRecordV1`
for trust, cost, and routing validation, and publishes the original record bytes
unchanged. It never publishes only the inner body and reconstructs the semantic
record as ASCII headers. EventWriter decodes those same `EdgeRecordV1` bytes and
then its contract body. Rollover or delivery reauthorization creates a new small
delivery wrapper around unchanged semantic bytes.

The numbered message and enum definitions are `proto/edge/v1/record.proto` and
`proto/edge/v1/sweep.proto`, frozen by the edge record v1 wire ABI change. Their
field meanings and presence rules are owned there and are not restated here.

The sink computes `semantic_envelope_sha256` from an explicit, versioned,
field-by-field signing-byte transcript over every semantic/trust field, committing
`payload_sha256`, and excluding the digest field itself and all delivery state. That
transcript is frozen and interoperable only when both languages implement it
byte-for-byte, per the frozen edge record v1 wire ABI. The domain, version constant, field order, and
framing are frozen THERE and are not restated here.

All UUID-backed identifiers (`spool_id`, event/trace/execution/plan/run IDs, and
source IDs stored as UUIDs) use canonical 16-byte UUID fields in the final
protobuf contract. A field retained as text for legacy compatibility MUST be a
validated lowercase canonical UUID representation, reject nil/noncanonical aliases,
and have identical Go/Elixir normalization fixtures.

Every v1 semantic `event_id` is RFC 9562 UUIDv7 allocated once before durable
spooling. Its UUIDv7 timestamp selects the trusted metadata retirement bucket
and must match the signed production/source-authorization interval plus the
defined terminal grace and clock tolerance. Because the UUIDv7 is minted before
spooling, the record body's authoritative observation/event time(s) MUST also fall
within the signed production/source-authorization interval (plus tolerance), and
the UUIDv7 timestamp is validated for consistency with that body observation
window rather than being the sole time checked. The same event ID therefore cannot
move between metadata partitions; recovery preserves it even when delivery
coordinates change.

The agent atomically persists the exact emitted `EdgeRecordV1` bytes plus the
delivery wrapper's spool ID, sequence, record checksum, and delivery capability
before sending. A retry within a lane reuses the wrapper and exact record bytes.
Crash-safe recovery MAY wrap the same record bytes in a new spool ID/sequence as
defined below. Only the delivery wrapper and deployment stream-map metadata may
change; event, contract/provenance/authorization/cost fields, semantic digest,
and payload bytes do not. The gateway MUST NOT advance an ACK past a missing or
failed delivery sequence.

Sequence space is scoped to a finite platform-owned delivery lane: durable
bulk, durable interactive, and a minimal separately reserved spool-recovery
control lane (plus a separately benchmarked continuous profile if required),
not to one payload family, plugin, or all traffic from an agent. Interactive is a
hard-size/rate/duration-bounded service class assigned by the scheduler, not a
caller-controlled priority bit. A blocked trace/plugin frame, bulk backlog, or
corrupt sequence therefore cannot prevent bounded interactive reachability or its
own audited loss recovery. Each lane uses an independent bidirectional RPC.
Bulk, interactive, and recovery RPCs use separately pooled HTTP/2 transport
connections with reserved connection-level windows and pending-byte ceilings;
they are not multiplexed onto one connection whose flow-control window can be
consumed by another class. Flow-control credits, reclaim watermarks, and spool
quotas remain independent.

The data-lane rollover protocol below does not recurse through a corrupt control
sequence. Recovery-control metadata is kept in a separately reserved,
double-written generation journal. If its active generation is corrupt, the
agent opens a fresh recovery-control generation under an explicit scheduler
recovery capability and reports the compact loss scope of the prior generation;
the gateway never requires the damaged generation's contiguous ACK to accept the
replacement. If neither journal copy can establish a trustworthy scope, the
agent stops durable-producer admission and the scheduler fences/times out
affected work; it does not claim recovery or durability.

Every lane opens with `spool_id`, route profile, traffic class, sequence base
(sequences start at one), first unresolved sequence, a fresh random session
nonce, and requested
byte/frame credits. The gateway echoes the nonce and negotiated credits. An
agent has one active sender per lane and ignores dispositions for an old nonce,
spool ID, or closed session. A replacement gateway reconstructs no private ACK
state: the agent replays from its first unresolved sequence, identical broker
IDs deduplicate accepted frames, and the gateway builds a new resolved prefix
from the declared base. Concurrent stale sessions may duplicate publication but
cannot reclaim the active spool or violate database correctness.

Volatile gateway disposition evidence has its own lifecycle, separate from both
watermarks. It may be evicted only after the ordered cumulative acknowledgement
covering it is successfully written and only when the same validated idempotent
publication path can reproduce the terminal disposition and authoritative PubAck
after a lost ACK, duplicate replay, or reconnect, without subscribing to stored
records or recovering private gateway state. Eviction itself advances neither
watermark and cannot authorize spool deletion. The standalone prefix tracker does
not own evidence eviction; tasks 3.4 and 3.5 must integrate that lifecycle with the
real Stream/publisher owner and prove that retained memory stays bounded over a
long-lived lane.

Each disposition on the wire is one of the generated `EdgeRecordDispositionKind`
members frozen by the ABI change. This change has SIX internal outcome names and
they map onto FIVE generated members, so the mapping is MANY-TO-ONE, not one-for-one:
`primary_publication` -> `EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE`,
`audit_publication` -> `EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUDIT_ONLY`, `quarantine_publication`
and `security_quarantine_publication` -> BOTH `EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_QUARANTINE`
(which is why their DLQ routes must stay distinct -- the reported member cannot tell them apart),
`permanent_rejection` -> `EDGE_RECORD_DISPOSITION_KIND_REJECTED_PERMANENT`, and
`retryable_rejection` -> `EDGE_RECORD_DISPOSITION_KIND_REJECTED_RETRYABLE`.
The wire `resolved_through_sequence` is the REMOTE terminal-disposition-through
watermark (what the gateway resolved): it advances only across a contiguous run for
which every sequence is accepted-authoritative (primary-stream PubAck),
accepted-audit-only (audit-stream PubAck), accepted-quarantine (quarantine-DLQ
PubAck), accepted-quarantine via the SECURITY-quarantine DLQ PubAck, or
rejected-permanent (reject-audit DLQ PubAck); a rejected-retryable
outcome leaves that sequence and every higher sequence unresolved and MUST NOT
advance the prefix. The agent maintains a SEPARATE durable local reclaim watermark
that advances a spool sequence only AFTER the agent's own local durability for that
sequence (for example the quarantine transaction that moves a permanently rejected
record) commits. The agent deletes accepted records, moves permanently rejected
records to durable local quarantine, and reclaims the spool using the LOCAL reclaim
watermark -- never the wire `resolved_through_sequence` directly. This permits
progress past poison data without describing a rejection as successful telemetry
ingestion.

Permanent protocol rejection is returned as a bounded structured disposition
after its deployment-local audit record has obtained a DLQ PubAck; the agent
quarantines the rejected frame locally and surfaces an operator alert. Raw bytes
that violate ingress size or trust bounds remain in that local quarantine and
the audit record carries only safe bounded metadata plus its checksum. Transient
gateway, NATS, DLQ, or capacity failures leave the frame unresolved.

Raw quarantine has explicit bulk/interactive byte accounting, an unborrowable
interactive floor, a total byte quota, retention policy, class-specific
high/low-water admission thresholds, and owner-acknowledged export/deletion workflow. Moving a
rejected record is an atomic crash-safe rename/index update, not an extra
unbounded copy; the spool prefix is reclaimed only after quarantine durability.
At quarantine high-water, new durable production and scan admission stop and
operator paging begins.
Bytes are never overwritten or silently expired, so a bad rollout cannot hide a
fleet-wide rejection storm by filling agent disks while the normal spool appears
healthy.

After a gateway protocol fix, fleet orchestration may issue an audited
reclassification instruction scoped to agent, rejection code/version, frame
fingerprint, and time cohort. The agent revalidates each selected quarantined
frame and crash-safely re-enqueues unchanged semantic bytes under new spool
coordinates and replacement delivery authority. This path is rate limited,
reports per-agent progress, and uses the normal semantic ledger for idempotency.
Local raw bytes are deleted only after accepted resolution or an explicit
operator waiver, not merely because the central audit record exists.

Production, source-action, and delivery authority are separate. The production
capability is the control-plane-signed effective output grant and binds exact
contract bundle, registry snapshot, package/assignment/run/scope, route profile,
traffic class, and quotas at record creation. A scanner collection capability,
integration-run grant, or command authority is a separate
`source_authorization`; output permission alone never authorizes probes, HTTP,
credentials, filesystem access, or an external side effect. Expiry immediately
forbids new source work and output. If immutable spooled bytes outlive their
production/source proof or their PubAck is lost across a fence, the control
plane may issue a short-lived delivery capability bound to origin, network
scope, spool ID/sequence, event ID, exact record checksum, original proof and
contract digests, and authorization scope. The renewed proof lives only in a
new or updated delivery wrapper; renewal does not change `EdgeRecordV1` bytes
and grants no production or source-action right. The consumer still applies current
authoritative fencing: pre-fence data may remain audit history but cannot
displace a replacement run. A record without valid original production proof and
either current production authority or explicit delivery authority remains
unresolved or quarantined; it is never silently relabeled as newly produced.

If crash recovery changes spool coordinates, a replacement delivery capability
also binds `recovery_id`, old and new coordinates, exact record checksum, and
the unchanged semantic digest. It is authorized only against the durable
rollover/recovery record; an old coordinate-bound capability cannot be replayed
for arbitrary bytes.

All capabilities are signed over the frozen Appendix A grammar 2 preimage that begins
with the capability-signing grammar frozen by the frozen edge record v1 wire ABI -- its domain tag,
version, field order, and framing are not restated here.

Compression defaults to none. Zstandard level 1 may be enabled per capability
only after CPU/wire benchmarks show a net benefit. Consumers use streaming
decompression with independent hard output and expansion-ratio limits, reject
unsupported dictionaries, concatenated/trailing frames, and excessive protobuf
recursion/depth, then verify the actual output size equals the declaration. The
declared uncompressed size is never trusted as an allocation authority.

## Decision 2a: Put a producer-neutral API in front of the transport frame

`EdgeRecordV1` and `EdgeDeliveryFrameV1` are agent-owned internal contracts, not
plugin ABIs and not evidence that producer-supplied body claims are true.
Built-in collectors, Wasm modules, native add-ons, and embedded integrations
submit bounded contract-payload (submission) bytes to one agent-owned producer
sink. The sink
validates the effective output grant, derives trusted identity/cost/routing
metadata, assigns stable semantic and spool identity, and fsyncs the common
spool. Producers never choose network scope, gateway, NATS subject, physical
stream, traffic class, spool ID/sequence, database destination, or projected
write cost.

Conceptually the local API is:

```go
type Sink interface {
    OpenRun(context.Context, ApprovedRun) (RunHandle, error)
    Publish(context.Context, RunHandle, Submission) (DurableReceipt, error)
    Checkpoint(context.Context, RunHandle, Checkpoint) error
    Commit(context.Context, RunHandle, TerminalManifest) error
    Abort(context.Context, RunHandle, AbortEvidence) error
}
```

A `Submission` contains an approved output-contract reference, a producer-local
stable idempotency key, bounded UNCOMPRESSED contract-payload bytes, and bounded
descriptive metadata. The sink computes `submission_sha256` over those
pre-compression submission bytes, performs the producer retry lookup BEFORE
compression, and then compresses the payload at most once. Producer instance,
assignment, run, and scope handles are host-issued
and unforgeable; caller-selected strings cannot create quota or identity
namespaces. The sink supplies or verifies agent/package/assignment/producer/run
identity, authorization, event ID, exact encoded size/hash, conservative cost,
traffic class, and route. It deterministically encodes `EdgeRecordV1` once,
then assigns the delivery lane/coordinates and wrapper. A retry of the same producer key
under the same assignment/run maps to the original semantic event; this closes
the crash window where the agent fsyncs a record but the producer does not
observe the return.

That guarantee is backed by one atomic durable binding from `(package digest,
producer assignment, host-issued run, contract bundle digest, registry/effective
grant digest, producer key)` to event ID, the pre-compression `submission_sha256`,
exact body digest, exact record digest/bytes, local-durability receipt, and later
disposition watermark, committed atomically with the delivery wrapper's spool
append. The same key with a different `submission_sha256` is a permanent integrity
conflict. Receipt lookup
returns the original identity after an uncertain timeout, agent restart,
producer restart, or lane rollover. The binding survives spool reclamation for
the signed producer retry/offline horizon and is retired only after the run is
fenced/terminal, that horizon has elapsed, and the semantic-ledger safe-GC
watermark has passed. A retry after retirement receives
`RETRY_WINDOW_EXPIRED`; it never silently allocates a new event under the old
key.

The frame gains a bounded output-contract reference and producer context. The
exact wire shape is finalized with the protobuf task, but its semantics are:

> The exact `EdgeOutputContractRef`, `EdgeOriginKind`, and `EdgeProducerContext`
> definitions are `proto/edge/v1/record.proto`, frozen by
> `freeze-edge-record-v1-abi`. Not restated here: a prose copy of a wire shape
> drifts, and one already did.

The semantic digest binds both messages plus the ingress-attested origin and
exact package version/digest. Standard contract IDs live in a reserved
`serviceradar` namespace. Extension IDs are assigned under an approved
publisher/package-signing namespace; another signer cannot take over that ID.
Scan-specific execution/range fields are one specialization of the producer
run/scope context rather than prerequisites for every record. The finite payload
family describes framing/lifecycle only; adding a third-party contract does not
allocate a new enum, subject, stream, consumer, connection, or database writer.

### Approved output-contract registry

Signed package metadata may request output descriptors: contract ID/version,
encoding, requested delivery/traffic profile, maximum record/frame/run bytes,
record count, rate, outstanding spool bytes, cost-model ID, and a schema/display
or processor-contribution reference. Import approval and assignment compilation
produce the effective immutable grant after intersecting that request with
platform policy. The registry snapshot is signed, immutable, content-addressed,
and maps every exact contract bundle to its validator/cost/projector, finite
route profile, partition rule, and lifecycle state. The agent, gateway readiness
logic, stream map, and EventWriter activate the same epoch/digest only after all
required historical bundles and processors are ready. An unknown, conflicting,
or not-ready contract receives no new production grant; rollout mismatch is not
converted into ordinary poison.

The contract digest covers the complete immutable processing bundle, not merely
the protobuf descriptor: canonicalization and unknown-field policy, validator,
authoritative-field rules, partition rule, cost model, projector engine/config,
retention/data classification, domain identity, revision/merge semantics, and
error policy. A durable contract's error policy may quarantine/DLQ or hold, but
may never silently drop an accepted record. Every referenced historical bundle remains resolvable through the
maximum agent-offline, spool, JetStream replay, DLQ/redrive, and producer-retry
horizon. The agent always runs the approved bounded structural validator before
spooling and either evaluates the pinned cost module or charges the contract's
fixed worst-case grant cost. EventWriter independently validates canonical form,
authoritative-field rules, and recomputes cost before side effects.

Planned contract retirement stops new grants while allowing immutable backlog to
drain against its pinned historical bundle. Security revocation is fail-closed:
matching new output and backlog are quarantined/held, collection and delivery
authority are disabled, and redrive requires an explicit operator-approved safe
bundle or waiver. A compromise is never treated as ordinary retirement.

Platform contracts such as sweep, MTR, `MetricBatch`, OTLP, OCSF, inventory,
and lifecycle events use compiled typed consumers. Package-defined extension
records are accepted only when the approved package contribution selects a
bounded platform-owned processor from
`add-event-writer-processor-contributions`. That active change MUST be amended
for this plane so edge dispatch keys on the trusted route/contract bundle over
fixed subjects, not a package-requested subject filter; it supplies the bounded
declarative processor vocabulary, not transport authority. Packages cannot upload executable
BEAM/native/JavaScript processors, SQL, DDL, or arbitrary subject filters.
Inventory retains a specialized DIRE-aware projector rather than becoming an
arbitrary row-mapping extension.

Processor engines are deterministic, side-effect-bounded platform code. Their
bundle declares maximum decoded bytes, fields/depth/cardinality, output rows and
write bytes, permitted destination family, lock set, transaction duration, and
data classification. They perform no network I/O, dynamic code loading, package
state mutation, SQL/DDL supplied by a package, or best-effort drop after a local
durable receipt.

### Local producer adapters and durability

- Built-in Go collectors call the sink directly.
- Wasm receives a versioned binary host ABI and SDK helpers that pass bounded
  protobuf bytes directly. One guest-to-host memory copy is expected; the ABI
  removes protobuf-to-base64-to-JSON and the reverse decode/re-encode path.
- Native add-ons receive one bidirectional record relay with byte/frame credits
  and cumulative local-durability ACKs. The add-on retains a record until the
  agent confirms common-spool fsync; the agent then owns gateway replay.
  Durable `StreamTelemetry` and `RelayOtlp` migrate onto this adapter, while an
  explicitly best-effort runtime-counter feed may remain lossy.
- Embedded integration drivers publish through the same sink. They retain
  provider API/pagination/mapping logic but do not own JSON chunking or
  `StreamStatus` delivery.

A synchronous Wasm call may wait for a short bounded group commit. Native and
in-process clients may pipeline within granted credits. Pressure returns an
explicit retryable `WOULD_BLOCK` with retry-after/credit notification; permanent
oversize, invalid-schema, revoked-contract, capability, and hard-quota failures
use distinct non-retryable codes. Cancellation or timeout while fsync outcome is
uncertain requires receipt lookup/retry with the same producer key. A durable
output is never reported successful and then dropped from a full memory channel.
The Wasm runtime enforces pause/fuel/CPU limits against a busy-looping guest.
Native relay sessions are bound to package assignment, host-issued nonce, and
resume watermark so a stale or same-host process cannot impersonate another
producer. A source that cannot honor backpressure is explicitly classified
lossy or loss-audited; it is not called durable.

### Output lifecycles

The record plane supports three bounded shapes:

1. independent immutable records;
2. bounded or perpetual runs with start/data/checkpoint/terminal epochs; and
3. atomic snapshots whose independently durable pages are activated only by a
   valid terminal manifest binding page count/ranges and content digest.

Every assignment caps concurrent runs, pages, records, bytes, checkpoints,
terminal attempts, outstanding spool bytes, and retained idempotency bindings.
Perpetual producers rotate bounded epochs. Terminal evidence uses a bounded
ordered Merkle/checkpoint root rather than enumerating an outage-sized page set.

Armis inbound discovery is the first inventory adapter. Each provider page
becomes a typed `DeviceInventoryObservationBatchV1`; a terminal records complete
or partial state, counts, page/range digest, source cursor, and collection time.
Pages are immutable staging records keyed by the assignment-authorized source
instance, control-plane-issued monotonic authority epoch, and host-issued run
ID. Neither a producer timestamp nor a caller-selected run ID orders snapshots.
Staged pages have no current-state or absence side effect. A terminal arriving
early remains pending until every declared ordinal/hash is present, page and
source-object-key uniqueness validates, and the bounded ordered
Merkle/checkpoint root matches. Snapshot pages and terminal use the same
contract-pinned logical partition key; processing may still arrive concurrently,
so correctness depends on database staging and fences rather than broker order.
One bounded transaction then fences older epochs and swaps the source's current
snapshot pointer; physical cleanup/reconciliation may continue asynchronously.
A late older terminal, conflicting page, same-epoch terminal conflict, or abort
after complete is poison and cannot replace current inventory. Partial/orphan
staging has bounded retention and GC after its replay/repair horizon.

Absence-authoritative completion additionally requires an assignment-scoped
provider snapshot token/revision or a contract-specific consistency proof that
the provider view did not mutate during pagination. Without it, a successful run
is upsert-only. The proof and terminal bind the exact source instance and
coverage scope, so one package cannot claim completeness for another source,
site, or range. A partial, inconsistent, or missing-page run never removes
previously current source inventory. Absence affects only that source
observation; it never deletes a multi-source canonical device or erases another
source's provenance.

The Armis northbound updater is different: its HTTP write is an outbound side
effect in the command/job plane. Core continues to select canonical desired
state and schedule/idempotently execute that action. If endpoint-side execution
later moves into a plugin, Core supplies immutable bounded update-plan pages;
the plugin emits progress, receipts, audit, telemetry, and terminal records
through this data plane. The authenticated reverse plan-delivery/secret channel
is a separate command-plane contract and is not created here. A durable receipt
proves only that the receipt record was stored, not that the external POST took
effect; edge-side execution would also require stable operation/idempotency
keys, ambiguous-timeout reconciliation, and response-secret redaction. The
external POST itself is not an ingress record.

### Finite routes, traffic classes, and lanes

An output contract is the semantic schema/projector agreement. A route profile
is a finite platform-owned transport, durability, retention, and cost/SLO class;
it never denotes sweep, MTR, inventory, a plugin, or another semantic family. A
traffic class is an immutable control-plane-assigned service class. A physical
delivery lane is one route-profile/traffic-class pair, plus the separately
reserved recovery-control lane; none is keyed by payload family, plugin ID, or
output-contract ID. V1 starts with one `durable-records-v1` route profile and
bulk/interactive traffic classes. An independently budgeted `continuous-v1`
route profile may be added only by a platform release and deployment migration
after benchmarks prove the shared route cannot meet both SLOs. A package may
request only an existing profile, and the effective grant—not the record body—
selects it. Byte-based DRR within a lane includes network scope, attested origin,
producer assignment, run/execution, and immutable traffic class. This prevents a plugin
or large inventory run from monopolizing the shared spool/sender without
creating one connection or RAFT group per plugin.

The platform deliberately retains four planes:

- command/execution for assignments, credentials, actions, and cancellation;
- durable record ingestion for observations, inventory, telemetry, and results;
- ephemeral state for coalescible heartbeat/current-progress data; and
- blob/media transport for artifacts, captures, files, tunnels, and live media.

The durable record plane may carry immutable artifact references and lifecycle
events, never an unbounded blob or live stream. Commands, credentials, provider
secrets, and outbound update-plan pages never masquerade as ingress records;
ephemeral state is never a durability acknowledgement. Artifact references are
bounded content identities and authorization-safe metadata, not bearer URLs or
embedded secret material.

## Decision 3: Keep sweep summaries and full MTR traces as separate correlated events

Physical co-location is not required for logical correlation. The sweep host
observation carries a small MTR outcome and stable `trace_id`; the complete
trace is a separate typed event.

### Sweep observation shape

> The numbered message definitions are `proto/edge/v1/record.proto` and `proto/edge/v1/sweep.proto`, frozen by the frozen edge record v1 wire ABI. Not restated here.

`tested_checks` plus the open-port list avoids repeating a closed result object
for every host/check pair while preserving TCP SYN versus TCP connect semantics.
Every host in one batch MUST have the exact same attempted check set; profile or
host overrides create a separate builder. The TCP summary, explicit error
entries, and `result_mode_bits` distinguish all-closed, skipped, incomplete, and
failed scanning. Batch-level modes and timestamps avoid repeated strings and
large absolute values. Plan/range IDs and digests replace repeated enumeration
of target scopes. Exact validation bounds are part of the schema task.

A host observation is a mergeable terminal-mode fragment, not a promise that
all configured modes finished simultaneously. ICMP/TCP may be emitted as soon
as they finish. A slower sweep-profile MTR run may later emit a fragment carrying
its small summary and trace ID. `mode_revision` is compared independently for
each mode named by `result_mode_bits`; a newer MTR fragment never suppresses an
unseen older ICMP/TCP fragment. Reusing the same network-scope/agent/execution/shard/
assignment/host/mode/revision key with different content is poison.

There is no fragment-global `available` boolean. Each mode carries an explicit
success/failure/skipped/not-admitted/timed-out/unknown outcome. After merging
the latest revision of every reported mode, the projector derives per-agent and
aggregate availability with the execution plan's versioned availability policy.
Unknown or unfinished modes never become false by omission; for an any-success
policy, a late MTR failure cannot overwrite an earlier ICMP success.

The scheduler persists an immutable `SweepExecutionPlan` header plus bounded
content-addressed range pages containing shards/ranges, expected target counts/
digests, configured modes/check sets, availability policy, and MTR admission
budget. CIDR/range inputs remain compact; arbitrary target lists use immutable
bounded pages and a plan root, never one database value, config blob, or command
containing every target. Page fetch, validation, caching, and assignment are
byte/count bounded. Assignment attempts are not part of that immutable plan: the
scheduler appends separate authoritative attempt records with agent, page/range,
epoch, lease/fence generation, the covered range window, and state. This permits
retries that did not exist when the plan was created. A retry covers the WHOLE
window, never a partial remainder -- see the whole-window rule below.

Each assignment attempt has exactly one sweep-data batch sequence space,
starting at one and allocated contiguously when batches become durable even when
multiple mode builders flush concurrently. Empty sequence numbers are forbidden.
The terminal evidence closes `[1, terminal_batch_sequence]` (or the empty
interval when it is zero), and persistence must prove every slot in that interval
has one non-conflicting binding. Compact range sets may represent the proof, but
`{1,3}` can never satisfy a terminal value of `3`. MTR trace batches use their own
identity/binding reconciliation and do not consume sweep batch slots.

MTR completion uses the completion-proof grammar frozen by the frozen edge record v1 wire ABI. Its
version, accumulator folding, leaf framing, and root composition are not restated
here.

The agent emits `SweepExecutionEventV1` start/progress evidence and, when it can,
one stable completed/aborted terminal evidence event per attempt. Those events
carry plan identity, assignment epoch, terminal batch sequence, cumulative
counts, scanner/banner summary, and expected/emitted MTR-summary and trace
counts/digests. If the agent disappears or cannot durably write its terminal,
the scheduler fences the attempt and atomically records an authoritative
`expired`, `superseded`, `lost`, or `aborted` terminal state before REASSIGNING THE
WHOLE RANGE WINDOW. v1 cannot express a sparse remainder: an assignment holds one
CONTIGUOUS plan-global ordinal window and its completion proof requires exactly
`{1..ordinal_count}`, so "what is left" has no representation. Narrowing coverage
needs the deferred bounded-subset grammar, not a smaller `ordinal_count`. Overall execution state is reconciled from the immutable
plan, append-only authoritative attempt records, and agent evidence; no
distributed agent authors a global completion record.

### MTR trace shape

`MtrTraceBatchV1` contains bounded `MtrTraceEventV1` records with:

- stable RFC 9562 UUIDv7 `trace_id` and event ID;
- source (`scheduled_check`, `sweep`, `ad_hoc`, or `on_demand`);
- optional sweep execution/host correlation, check ID, command ID, and device
  hint, including `scan_run_id` for ad-hoc runs;
- one Unix-nanosecond observation timestamp;
- explicit attempted/outcome/error state;
- target, resolved address, protocol, IP version, packet size, and reachability;
- bounded hops with ECMP addresses, MPLS labels, sent/received, loss, optional
  RTT/jitter values, and a nonnegative 32-bit ASN represented safely on wire and
  as `BIGINT` in PostgreSQL.

Every trace in one `MtrTraceBatchV1` MUST share the frame's authenticated
network scope, agent, source class, authorization kind/context, and, when applicable, sweep
execution/shard/epoch/range. Sweep, scheduled-check, ad-hoc, and on-demand
contexts are never mixed in one frame. The outer capability covers the complete
batch and the consumer verifies every decoded record against it before any side
effect; a mixed-context batch is poison. Builders flush when any context changes,
even if the byte target has not been reached.

Timing fields whose absence differs from a measured zero MUST use proto presence.
Routing and producer identity come from the agent sink's trusted
`EdgeRecordV1` context and signed grants, verified by the gateway and
EventWriter; neither payload-body claims nor broker headers are authoritative.

The wire preserves Unix nanoseconds, including signed host deltas, while CNPG
`timestamptz` stores microseconds. THE CANONICALIZATION IS PROJECTION-DOMAIN ONLY: before
any projection-domain STORAGE OR ORDERING COORDINATE -- not a projection hash and not an
identity comparison, neither of which consumes a canonicalized time -- every
implementation canonically truncates nanoseconds toward negative infinity to the containing
PostgreSQL microsecond, and separately stores the original signed `observed_at_unix_nano`
wherever sub-microsecond fidelity is part of the domain/audit contract.

IT SHALL NEVER FEED EITHER CONTRACT HASH. `payload_sha256` is taken over the EXACT CARRIED
PAYLOAD BYTES -- the decoder imposes no decode/re-encode equality for exactly that reason --
and `semantic_envelope_sha256` is taken over the frozen FIELD-FRAMED TRANSCRIPT, which commits
`payload_sha256` and the RAW NANOSECOND values rather than any canonicalized form.
Canonicalization is what the database-derived keys and ordering are computed from, AFTER both
hashes exist. Feeding it into either would make the contract depend on a normalization step
instead of on what was received. Negative delta arithmetic is checked for
overflow. Shared vectors cover the boundary rows so Go and Elixir cannot disagree about the
mathematics. SQL AGREEMENT IS NOT YET ESTABLISHED: nothing calls the conversion from a
projector today, so no fixture exercises the value as written and read back. Task 5.4 owns that
integration, and the claim becomes true when it lands.

For every MTR producer, the producer allocates and durably records an RFC 9562
UUIDv7 `trace_id` before starting the probe. Its timestamp is the immutable
`trace_identity_time` and MUST fall within the signed collection interval plus
the configured attested-clock tolerance. The same ID survives encode, spool,
transport, and delivery retries, and a sweep/ad-hoc summary and trace event use it
verbatim. A restarted probe attempt receives a new attempt/event ID but remains
correlated to the same execution target; it MUST NOT overwrite a different
completed trace under the old ID.

The existing `MtrTraceResult` and `MetricBatch` shapes may be used as migration
inputs, but they are not the canonical v1 trace contract until timestamp,
presence, ASN, correlation, and failure-outcome defects are corrected.

## Decision 4: Treat every producer run as a continuous bounded record stream

Every finite producer run opens under an approved assignment/grant, emits
independently useful bounded records while work continues, checkpoints at
bounded count/time intervals, and ends with a stable complete, partial, or
aborted terminal. Transport EOF is never a run terminal. Atomic snapshot
contracts add a terminal manifest that binds all required pages; they do not
buffer the whole snapshot in one message or activate absence semantics early.

The scanner specialization changes from whole-run snapshot delivery:

1. Reference the immutable scheduler plan plus append-only assignment attempt and
   emit start evidence for the attempt; processing does not depend on that event
   arriving first.
2. Process targets in bounded windows (initial range 4,000-16,000 hosts,
   benchmark tuned).
3. Retain a host only until the modes in its current execution phase reach a
   terminal outcome; do not retain completed ICMP/TCP state while waiting for a
   slower MTR phase.
4. Feed completed hosts into execution-shard batch builders while later target
   windows are still scanning.
5. Flush a builder when `proto.Size` approaches 256 KiB or a short flush timer
   expires; never exceed `MaxRecordBytes`, the item guard, or the projected database-row
   budget.
6. Append the encoded domain batch and frame metadata to an fsynced segmented
   spool before it becomes eligible for transmission.
7. Release completed host/port state after the frame is durably spooled.
8. Emit bounded progress/watermark events at configured count/time thresholds,
   not once per host or delivery retry.
9. Emit one stable completed or aborted terminal evidence event after the
   shard/range has closed, including terminal batch sequence, cumulative counts,
   and expected/emitted MTR trace reconciliation data. If that is impossible,
   scheduler lease/fence recovery terminalizes the attempt as lost/superseded and
   REASSIGNS THE WHOLE RANGE WINDOW for retry. v1 has no partial-remainder input: the
   window is contiguous and is replayed complete.

The data plane is continuously pipelined: scanning, encoding, spooling, gRPC
transmission, JetStream persistence, consumption, and database projection may
all be active for the same execution at once. Each data batch is useful without
agent start or terminal evidence. That evidence and authoritative assignment
state control execution status; the immutable scheduler plan defines expected
work. None is a prerequisite for processing or querying already durable
observations.

The same rule applies at every MTR producer. Scheduled checks, sweep-profile,
ad-hoc, and on-demand runners use bounded probe concurrency and feed each
completed trace directly into the byte/row/write-cost/timer builder and fsynced
shared lane selected by the platform route/class map. They release the trace/hop object after append and never accumulate a
run- or interval-wide slice of completed traces before encoding. MTR producer RSS
is therefore bounded by active probes plus one builder/spool window, not due
trace count.

The long-lived bidirectional gRPC lane is only a multiplexed carrier. It may
remain open across many executions, and frames from different executions may be
interleaved by the fairness scheduler. RPC EOF, reconnect, or half-close never
means that a sweep completed; only authoritative attempt terminal state plus
plan/range reconciliation can establish completion. Conversely, finishing one
execution does not require closing or draining the connection before another
can make progress.

For a genuinely perpetual producer, the same framing rule uses bounded
time/config-generation epochs and durable watermarks instead of pretending the
entire lifetime is one execution. Consumers process each record independently,
advance event-time/sequence watermarks, and rotate epochs without waiting for
transport EOF. This proposal applies that rule to every approved durable
producer contract. Adding another continuous observation type still requires an
approved typed or extension schema, cost, retention, admission, and projector
contract; it does not require another transport lane.

For well-formed events with non-conflicting stable identities, correctness does
not depend on broker arrival order, including within a run shard. Stable
`(network_scope_id, producer_assignment_id, run_id, run_shard,
authority_epoch, record_sequence)` and event IDs permit safe interleaving,
retry, reassignment, and late arrival. Sweep execution/shard/assignment/batch
keys are the corresponding domain specialization.
Partition affinity improves ownership and cache locality only. Consumers track
compact committed ranges/watermarks per assignment attempt; start or terminal
evidence may arrive first and trigger reconciliation again when missing data
commits. A producer that assigns two different payloads to one immutable identity
has violated the protocol and follows the explicit conflict rule below.

Initial secondary guards are 2,000 sweep hosts per batch and 128 MTR traces per
batch. Initial hard projected-row budgets are 10,000 sweep projection rows and
5,000 MTR trace/hop/path-variant rows per message. Encoded bytes, projected rows,
or projected write bytes always win over item count. The versioned cost contract is a conservative
worst-case count of every synchronous row mutation and of decoded resident/SQL-
parameter/index/WAL bytes, not merely encoded payload length. It includes ledger
and batch-slot/trace-identity bindings, host/check/error,
history/current state, OCSF, execution evidence, MTR correlation, trace/hop/path
variants, graph/reconcile outbox, and low-cardinality projection rows, plus fixed
per-message overhead. The producer cannot subtract likely conflicts or no-ops.
The consumer independently recomputes and verifies both upper bounds before
writing, and a schema version cannot ship without golden fixtures enumerating
every projector it can invoke. A single host or trace cannot
exceed the hard byte/row limit because check, hop, ECMP, label, hostname, and
metadata counts/lengths are bounded at collection time. An unexpected oversize
record is quarantined and reported rather than retried forever.

Each lane's spool is byte-bounded using the larger of two maximum planned outputs
or the configured production rate times the supported gateway/NATS outage, with
at least 25 percent headroom. Those lane limits are subordinate to one atomic
filesystem allocator covering every lane, the producer-receipt/idempotency
journal, raw quarantine, both recovery-journal copies, rollover copy
amplification, directory/segment metadata, and the AGGREGATE recovery reserve --
destination segment, attribution sidecar, BOTH journal copies, manifest/tombstone
pages, the old->new mapping, and filesystem metadata, times the bounded number of
CONCURRENT recoveries. A one-segment scratch reserve counts only the input and
none of the artifacts a recovery must durably write. The allocator enforces a hard minimum-free-space floor reserved for
recovery/control and terminal evidence; the sum of nominal lane quotas can never
overcommit the filesystem. When a lane or the global allocator reaches its
high-water mark, the scheduler defers lower-priority or overlapping work and
alerts. It never overwrites unacknowledged records or consumes the reserved floor
for ordinary data.

Admission reserves a conservative worst-case output budget for every new target
window and keeps separate emergency capacity for terminal/aborted metadata and
quarantine bookkeeping. Active aggregation is capped by bytes as well as host
count. No new window starts unless its reservation fits. High/low watermarks add
hysteresis; a hard watermark stops new probes and either resumes before the
execution deadline or emits an aborted terminal event from reserved capacity.

Spool records are length-delimited and checksummed, segment creation/rename and
directory metadata are fsynced, ownership/mode are private to the agent, and the
persistent sequence high-water is never reused. Startup truncates only an
uncommitted torn tail and quarantines corrupt committed segments without
silently skipping them. `ENOSPC`, `EIO`, fsync failure, or corrupt metadata
stops all durable-producer admission immediately, preserves the bounded current
window for retry when possible, marks the run delivery-failed/paused, and
alerts. A producer record is never released or reported durable until its
record bytes, delivery wrapper, receipt binding, and spool metadata are durable;
if the process dies first, the control plane retries or fences the unfinished
run/scope according to its contract.

A corrupt committed record in the middle of a lane is not silently skipped and
does not permanently pin every later valid record. Using separately reserved
recovery metadata/capacity, the agent durably fences the old lane from normal
publication, creates a new spool identity, and records a crash-resumable rollover
journal. Normal spool admission permanently reserves the aggregate recovery
budget defined above. The agent copies one readable old segment at a time to the
new lane by placing the exact unchanged
`EdgeRecordV1` bytes/checksum in a new `EdgeDeliveryFrameV1`, fsyncs the new
segment and copy watermark, and only then advances the journal.
That exact old source segment may be deleted before copying the next ONLY once the
coverage proof holds for every unreclaimed ALLOCATED sequence it held -- each one
either a FULLY COMMITTED, SENDER-VISIBLE destination slot (its own commit evidence
covering wrapper/coordinates, rebound attribution, old->new mapping, destination
high-water, and directory metadata) or a PubAcked frozen classification span whose
covered sequences are each backed by durable PER-SEQUENCE loss evidence whose
journaled classification matches the span's complete oneof body. An fsynced copy plus
a PubAcked tombstone is NOT sufficient on its own, and neither is the PubAck alone --
a widened span cannot show whether an omitted sequence was lost or preserved, nor
whether its body is the one the coordinator journaled. Recovery
therefore needs bounded scratch rather than a second full-spool allocation. Copying to a new spool ID/sequence is a
delivery-coordinate change; database semantic idempotency absorbs any original
publication whose PubAck or edge ACK was lost.

The agent also submits a journalled, content-addressed, hard-size-bounded
`SpoolLossTombstoneV1` (NOT agent-signed; no agent-signature ABI exists) on an
independent recovery-control lane. It names the abandoned spool, the destination
`new_spool_id`, the cryptographic segment/quarantine manifest root with its page
count, and the reason. The tombstone does NOT carry the spans: the ordered
`classification_spans` list lives on `EdgeLossManifestPageV1` (each span carrying
its physical interval plus an ATTRIBUTED_ACTIVE / ATTRIBUTED_PASSIVE /
UNATTRIBUTABLE(reason) body, replacing the former lost-interval +
affected-summary pair), and the tombstone binds them by committing that root and
count. Putting the list in both messages would restore the dual-schema ambiguity
1.6a removes. It never enumerates
millions of later recoverable records; those records are evidenced by their
fsynced copy and are simply re-enqueued. A destination copy authorizes source
deletion only when it is FULLY COMMITTED AND SENDER-VISIBLE -- its own commit
evidence covering the new wrapper/coordinates, rebound attribution, old->new
mapping, destination high-water, and directory metadata -- and coverage is
required for every unreclaimed ALLOCATED sequence, not only committed slots. If loss metadata itself cannot fit one
record, pages share a stable `recovery_id`, page count, ordered page digest chain,
and terminal manifest; the terminal page records copy completion or a bounded
failed/uncertain remainder. Both page size and total page count/manifest bytes are
hard bounded, and measured against the EXACT RECEIVED page bytes rather than a
re-marshalled canonical form. When interval detail would exceed them, the producer
SPLITS the recovery across manifests; it never coarsens proven attribution into
one uncertain scope. Coarsening may merge only CONTIGUOUS LOST intervals whose
COMPLETE CLASSIFICATION BODIES are equal -- not merely a shared attribution key,
since an UNATTRIBUTABLE body has none and two ACTIVE spans can share an identity
while differing in range_sha256 -- and never across a gap, because a sequence outside
the union is frozen as not-lost and the widened span can reach reclaim coverage. Both
rules are COORDINATOR CONSTRUCTION refusals over journaled per-sequence evidence, not
receiver checks: the final span reveals neither the omitted sequence nor the
precursor bodies. Known attribution is never relabelled UNATTRIBUTABLE to shed bytes -- that
would forge a claim that provenance could not be proven while the spool still
holds it. Admission reserves the entire
manifest, all pages share an assembly deadline inside the recovery retention
window, and the agent retries them until the durable page store records terminal
completion. Each page obeys the normal record limit. The recovery consumer durably
stores pages idempotently and applies partialization/fencing/retry exactly once
only after the complete manifest validates; an early page cannot expire while a
later required page remains admissible.

The scheduler issues a spool-recovery capability bound to network scope, agent,
abandoned SPOOL, affected attempts, recovery ID, and expiry -- NOT to an abandoned
range, which after 1.6a is not a single interval. Pages are NOT
agent-signed: no agent-signature ABI exists. Page integrity is the journalled
content-addressed chain, and authenticity is the authenticated session plus that
capability, which the gateway verifies along with the chain. The gateway publishes
pages to the deployment recovery stream with stable IDs derived from IMMUTABLE
identities only. The PUBLICATION id may include content digests so conflicting
bytes reach the consumer; the DURABLE key must not. Durable page key is
(network scope, authenticated agent, recovery ID, page index), comparing one fixed
page digest; durable recovery key is (network scope, agent, recovery ID),
comparing the COMPLETE immutable tombstone identity: abandoned/prior spool,
`new_spool_id`, manifest root, and page count. `coarsened` is not compared
independently, and after 1.6a there is no page `coarsened` bit to compare: tag 7 is
removed and reserved.
`new_spool_id` is signed by the
tombstone scope, so omitting it from the comparison lets a same-key replay naming a
DIFFERENT destination look identical. The tenant/agent
namespace stays in the PER-PAGE identity too -- the deployment recovery stream is
shared, so dropping it would let one agent's page collide with another's; removing
the obsolete loss range never required removing the trust namespace. A "lost scope" or abandoned RANGE MUST NOT appear in
either binding: after 1.6a the exact loss is the ordered span union and no single
interval describes it, so binding identity to one would make the identity
unstable or wrong. An old segment is physically deleted
only after the coverage proof accounts for every unreclaimed ALLOCATED sequence it
held -- each a fully committed, sender-visible destination slot, or a PubAcked
frozen classification span whose covered sequences are each backed by durable
PER-SEQUENCE loss evidence congruent with the span's complete oneof body; an fsynced
copy and mapping watermark alone are NOT sufficient, and neither is a PubAck alone; full old-lane retirement also
requires the terminal copy-completion page. The journal distinguishes publication
fencing, per-segment copy, recovery publication, and physical deletion, and
startup resumes any phase idempotently. A dedicated recovery consumer atomically
stores the loss audit, marks affected attempts/ranges partial or lost, fences
unsafe authority, and invokes the contract-specific partialization/retry action
(for sweep, REASSIGNING THE WHOLE AFFECTED RANGE WINDOW -- v1 has no
partial-remainder retry) before ACKing the completed recovery
state. Recovery state and lag are operator-visible
and retained beyond the recovery stream's replay window. This is explicit
acknowledged data-loss handling, not a success disposition for the missing
result.

Recovery identity is immutable independently of broker deduplication. A binding
keyed by `(network_scope_id, agent_id, recovery_id)` fixes the COMPLETE immutable
tombstone identity -- abandoned/prior spool, `new_spool_id`, manifest root, and page
count. There is no `coarsened` value to compare after 1.6a removes the page bit. `new_spool_id` is signed by the tombstone scope, so omitting it here
would let a same-key replay naming a different destination look identical. The
committed manifest root IS the loss commitment, and there is no "conservative loss
scope" interval after 1.6a. Each
`(network_scope_id, agent_id, recovery_id, page_index)` fixes one page digest. A later conflict is quarantined as integrity
failure and cannot apply a second partialization/fence/retry transition.

Recovery-stream PubAck only stops publication retry; it does not allow the agent
to garbage-collect its recovery journal. After the consumer transaction commits,
the scheduler returns a signed `RecoveryResolvedV1` over the control stream (or
an idempotent control query) bound to recovery ID, manifest root, and applied
state. The agent retains both journal copies and page proof until that resolution
is durable locally. A lost resolution is queried/replayed safely.

Admission, probe execution, and send scheduling use weighted fairness across
site/network scope, agent, execution, and traffic class. Each agent reserves an
unborrowable interactive floor for probe workers, sockets/file descriptors, ICMP
tokens, DNS concurrency, CPU, spool bytes, and sender credits; bulk work cannot
occupy it before an interactive assignment arrives. Interactive/on-demand work
remains hard-bounded and cannot bypass durability or starve scheduled work. MTR
has an independent byte/probe budget from reachability summaries. These policies
avoid head-of-line blocking when a million-target scan shares an agent or gateway
with small jobs.

## Decision 5: Make the gateway an authenticated pass-through publisher

For every delivery frame the gateway:

1. Authenticates the installation trust domain and agent through the canonical
   edge mTLS identity resolver (deployment CA and certificate subject/CN; a
   SPIFFE URI SAN is optional compatibility metadata, not a requirement).
2. Bounded-decodes `EdgeDeliveryFrameV1`, verifies lane/session, spool sequence,
   exact `record_bytes` checksum, and any delivery-only capability, and retains
   the original record binary. Delivery proof never changes semantic authority.
3. Bounded-decodes `EdgeRecordV1` without decoding its domain payload. It
   compares the claimed origin principal/network scope to mTLS, resolves the
   exact historical output-contract bundle and signed registry/effective grant,
   recomputes the semantic digest, and enforces route profile, payload family,
   producer/package/assignment/run provenance, production/source authorization,
   size/checksum/cost, revocation/fence, and in-flight bounds. Carrier
   provenance is authenticated; equivalent identity, scope, class, or source
   claims inside the domain payload remain untrusted until EventWriter validates
   or replaces them. No per-record core/DB/ERTS lookup is allowed.
4. Computes the logical partition from the platform-owned rule pinned in the
   approved route/contract bundle and authenticated outer context. Sweep may
   hash network scope plus execution/shard; MTR may hash scope, agent, and event
   ID; snapshot pages may hash source assignment plus run. The gateway never
   decodes a plugin body or accepts a caller-selected partition.
5. Selects the fixed route-profile/class subject, stream-map version, and
   expected physical stream.
6. Derives `Nats-Msg-Id` under the frozen `msgid` transcript grammar, so a
   re-encoded record reusing the same slot yields a DIFFERENT Msg-Id and its
   physical conflict is not broker-suppressed; sets `Nats-Expected-Stream`; and
   adds only bounded transport diagnostics for delivery ID and route-map version.
   It does not copy semantic fields into headers. The transcript's domain, version,
   and ordered inputs are frozen by the edge record v1 wire ABI and are not
   restated here.
7. Publishes the exact original `record_bytes` with a JetStream request and
   waits for PubAck.
8. Returns accepted/rejected dispositions and advances only the contiguous
   resolved spool prefix after the required PubAck for a primary-stream,
   audit-stream, quarantine-DLQ, SECURITY-quarantine-DLQ, or reject-audit-DLQ
   disposition; a retryable rejection never advances it. The security-quarantine
   PubAck is listed EXPLICITLY because both quarantine variants collapse onto one
   wire member: omitting it from an exhaustive list lets a compromise-revoked
   record reach its DLQ and then pin the resolved prefix forever.


The JetStream body is the exact deterministic `EdgeRecordV1` binary produced and
fsynced by the agent sink. Its semantic identity, contract, provenance,
authorization proofs, cost, and domain payload travel together in that binary.
The only normal NATS headers are transport metadata:

```text
Nats-Msg-Id
Nats-Expected-Stream
Sr-Edge-Delivery-Id
Sr-Edge-Transport-Provenance
```

`Sr-Edge-Delivery-Id` is one opaque transport digest over the frozen `edge_slot`
tuple, whose members and order are defined by the ABI change's Appendix A and are
not restated here -- the slot IDENTITY, not its content; the `record_sha256` bound
to that slot is carried in `Nats-Msg-Id`, in `Sr-Edge-Transport-Provenance`, and
stored in the delivery-slot binding, not folded into this slot-key header. It
permits delivery-coordinate conflict audit without duplicating coordinates or
semantic fields as text.

`Sr-Edge-Transport-Provenance` is a bounded TYPED, versioned,
PUBLISHER-authenticated transport-provenance envelope: the GATEWAY stamps it for
EDGE records and the governed SERVICE stamps it for SERVICE-INGRESS records, each
over its own isolated per-class publisher subject. Its domain tag, version
constant, slot-kind discriminants, ordered fields, presence rules, encoding, and
byte bound are frozen by the edge record v1 wire ABI and are NOT restated here;
what this change owns is WHO stamps it and what a receiver does with it.

The provenance-carried `route_map_version`
is diagnostic placement metadata. EventWriter MUST NOT use these headers as
semantic or authorization truth; it derives and verifies all such state from
`EdgeRecordV1` and the pinned registry bundle. Delivery-only capability remains
in the gRPC wrapper and is not persisted as semantic record data.

`Nats-Msg-Id` is a publication identity derived from the `Nats-Msg-Id` transcript,
which is frozen by the edge record v1 wire ABI change; its framed members are not
restated here.

EventWriter bounded-decodes the binary record, verifies its semantic digest and
production/source proofs, resolves the exact pinned contract bundle, then
decodes the declared contract payload and compares every body-level agent,
scope, source, package, assignment, run, target/range, and traffic-class claim
with record/grant authority. Before side effects it validates domain identity,
revision/merge rules, authoritative-versus-derived status, and any scanner
target/check plan membership. The ingest ledger stores and compares
`semantic_envelope_sha256` (which transitively commits `payload_sha256`), catching
conflicts outside the broker duplicate window; `record_sha256` MAY be stored for
audit but is excluded from the event-conflict comparison. This preserves opaque pass-through at the gateway without
treating either payload claims or transport headers as authorization truth.

Publishing may pipeline 32-64 asynchronous PubAcks. Every class uses a separate
NATS publisher connection/pool with its own pending-byte ceiling, so bulk client
buffering cannot consume the interactive or recovery path. Admission is bounded
by delivery/record count, exact encoded bytes, and measured retained gateway
memory including delivery-wrapper and record-envelope decode terms, pinned
original record binaries, proof verification, NATS request state, mailboxes, and
TLS buffers, not a raw-payload estimate alone. The three decode stages have FROZEN
raw byte bounds, checked BEFORE protobuf decode (an oversize input is a permanent
rejection, never an unbounded decode): `MaxRecordBytes` for `EdgeRecordV1`,
`MaxFrameBytes` for `EdgeDeliveryFrameV1`, and `MaxClientMessageBytes` for
`EdgeRecordClientMessage`. Their VALUES are frozen by the edge record v1 wire ABI
change and are deliberately not restated here. The same named constants are shared by
the Go `edgerecord` package and the Elixir `WireDecode` boundary; smaller contract
limits may apply. Lost
edge ACK after a successful PubAck is
safe: a retry in the same lane uses the same broker publication ID even if
delivery authority or physical placement changed. Recovery under new spool
coordinates uses a new publication ID but the same semantic digest. Reusing a
semantic event ID with different SEMANTIC fields produces a different semantic
digest and publication ID, so the consumer ledger rejects it as
`EVENT_ID_CONFLICT`. Reusing one delivery slot with different OUTER record bytes
(a different `record_sha256`) but an identical semantic digest also produces a
different publication ID -- because `record_sha256` is part of the `Nats-Msg-Id`
transcript -- so JetStream forwards both copies and EventWriter's delivery-slot
binding rejects the second as a transport-integrity violation, rather than
JetStream hiding it as a duplicate. Database idempotency remains the
correctness backstop after the broker duplicate window expires.

The current generic `Gnat.pub` wrapper is insufficient for this path because it
only confirms handoff to the client connection. A shared project-owned
JetStream publisher must parse and validate PubAck responses.

The gateway does not enqueue this lane into `StatusBuffer`. NATS unavailability,
stream capacity refusal, or publisher saturation stops ACK progress and lets
gRPC plus the agent spool apply backpressure.

The PubAck must come from the configured authoritative durability stream. A
Core NATS handoff through a leaf connection, a local non-authoritative mirror,
or an ERTS send is not sufficient. A deployment MAY designate an edge-local
JetStream as authoritative only when its replication and site-loss RPO are
explicitly configured and surfaced; otherwise the acknowledgement must reflect
acceptance by the hub durability domain.

## Decision 6: Use dedicated, partitioned JetStream streams

The runtime has one installation NATS authority with least-privilege component
credentials and fixed signal contracts. It does not prefix subjects or allocate
accounts, streams, durables, processes, or database schemas per SaaS customer;
the SaaS control plane provides customer isolation by provisioning separate
clusters. Legacy customer-prefixed runtime subjects/imports/mirrors and
`default`-customer inference are sealed and drained under an explicit migration
watermark, never extended by this data plane.

Initial subjects are installation-local and fixed for the
`durable-records-v1` route profile:

```text
telemetry.edge-record.v1.bulk.pNN
telemetry.edge-record.v1.interactive.pNN
telemetry.edge-record-recovery.v1
telemetry.edge-record-dlq.v1.bulk.pNN
telemetry.edge-record-dlq.v1.interactive.pNN
```

Output contracts share these subjects and are dispatched from the verified
binary record contract reference. A package cannot contribute a subject filter. Adding or changing a
finite route profile is a platform deployment change with a versioned stream-map
barrier; importing a package is not.

The effective control-plane grant attests the disjoint traffic class; no message
matches both. Traffic class is immutable for a producer assignment/run and is
bound by its signed production grant and applicable source authorization,
semantic envelope, subject, and stream-map entry. Gateway
validation requires all four to agree. Replay, rollover, and DLQ redrive preserve
the original class; they cannot promote bulk data into the interactive reserve.

V1 uses 64 logical partitions (`p00` through `p63`) with a versioned hash. The
benchmark may raise the count before rollout, but it cannot change after data is
published without a new subject/hash version. Each output-contract bundle pins
one platform-owned partition rule over authenticated outer context; it never
reads a plugin-selected partition. Run-oriented records such as sweep shards or
inventory pages may stay together by assignment/run/shard, while independent
records such as MTR traces may distribute by stable event ID. Large runs are
sharded by the scheduler so no agent/run depends on cross-partition ordering.
Recovery-lane coordinate changes never change the semantic partition key, and
consumers require no per-record broker arrival order.

A logical subject partition is routing and locality metadata, not an exclusive
application-worker ownership key and not automatically a
JetStream storage shard. Each physical stream has its own replicated state and
write leader. Provisioning therefore maintains an explicit mapping from every
logical partition to exactly one authoritative physical stream. A small
installation maps all partitions for each `(platform route profile, traffic
class)` to its own physical stream; bulk and interactive never share a stream or persistence
durable. Larger installations spread disjoint partition subject sets across more
physical streams/RAFT groups. The versioned map key
is `(traffic class, platform route profile, logical partition)`, and gateways
and consumers receive the same configuration.
The gateway persists its map version and uses the selected physical name for
`Nats-Expected-Stream`; overlapping or missing subject authority fails
readiness. A map-version change uses a distributed publish barrier: stop affected
admission, revoke or wait out every old-generation gateway lease, seal/remove the old stream's writable
subject authority and ACL, then activate exactly one new authority. The old
consumer remains alive after sealing to drain all accepted messages through the
final AckWait/redelivery horizon and a repair scan. A stale gateway therefore
gets no authoritative PubAck and cannot strand an
edge-acknowledged message after a drain snapshot. Publishing may resume on the
new authority while the sealed old stream drains. Increasing the logical
partition count alone is not a broker-write scaling mechanism.

Every immutable stream-map version, subject authority, publisher fence, and
consumer configuration is persisted through the old stream's empty/repair,
AckWait/redelivery, and rollback watermark. An old consumer can restart from
that history after a newer map activates; latest-config-only reconstruction is
not allowed.

All durable-record output contracts share the finite route map; bulk and
interactive classes use disjoint file-backed physical streams and pull durables
inside the installation's NATS authority. Gateway credentials can
publish only the fixed record subjects and read PubAcks, never subscribe to
records. This proposal creates no cross-cluster record aggregation path.

The low-volume recovery subject uses a separately capacity-reserved file-backed
stream and one idempotent scheduler-repair durable per installation. It is not
the poison DLQ: its consumer has a required state transition and
ACKs only after the loss audit plus attempt/range partialization/retry intent
commit. Its retention, lag paging, and `DiscardNew` headroom cover the supported
outage/catch-up window so a recovery claim cannot expire silently.

Record DLQ partitions map deterministically from the source data partition and
retain the attested original traffic class; a gateway rejection that has no valid
source partition hashes authenticated agent/spool coordinates and uses the class
from its verified capability. Bulk and interactive use disjoint physical streams
and consumers, never a shared-stream substitute and never the recovery-control
reserve. DLQ `MaxAge` is disabled: unresolved raw
records are removed only by audited state-aware deletion. `MaxBytes`, replicas,
and PubAck throughput cover the full admitted source rate for the configured poison
detection/pull-pause interval plus bounded in-flight/retry overlap. Per-shard and
aggregate poison-rate/ratio circuit breakers pause the affected source pulls and
new gateway acceptance and page immediately when a decoder/schema regression can
turn ordinary fleet traffic into poison. The system does not continue draining a
systemic failure into the DLQ until it fills; individual source messages remain
unresolved whenever the mapped DLQ cannot PubAck.

After admission pauses, DLQ capacity retains that bounded poison cohort through
the supported incident-diagnosis, rollback, redrive, and audit-resolution window.
No raw record expires merely because diagnosis takes longer than detection.
Bulk poison cannot consume the interactive DLQ floor or prevent an interactive
rejection from reaching a durable disposition. Circuit accounting, catalog
state, and redrive preserve original class. Final deletion requires an explicit
resolved/redriven/waived state and advances
the semantic-ledger safe-GC watermark; otherwise operators must extend capacity
or the path remains not ready.

A bounded DLQ indexer populates an idempotent `edge_record_dlq` catalog keyed by
stable DLQ ID and physical stream/sequence. The catalog records immutable source
provenance, error cohort, redrive attempts/outcomes, waiver, audit actor/time, and
final state. An authorized deleter removes only stream sequences whose catalog
entry is durably resolved/redriven/waived and whose dependent ledger watermark is
safe. Gateway publication remains stateless; unknown/unindexed sequences are
never guessed or purged.

Production streams use three replicas where the deployment supports them, a
hard maximum message size of `MaxRecordBytes` plus headers, `LimitsPolicy`, and
`DiscardNew`. Refusing new data propagates backpressure; silently evicting any
unconsumed durable record is not an accepted overload policy.

Capacity is calculated per installation and physical stream shard from an admitted
arrival envelope:

```text
catch_up_seconds = outage_bytes / (drain_bytes_per_second - live_bytes_per_second)
retention_horizon >= supported_outage + catch_up_seconds + safety_margin
max_bytes >= 1.25 * (
  max_admitted_bytes_in_any(retention_horizon)
  + maximum_spool_replay_overlap_bytes
  + measured_jetstream_record_overhead_bytes
)
```

`max_admitted_bytes_in_any(T)` includes synchronized scheduled bursts across all
sites/agents/executions sharing the physical stream, live traffic during recovery, retry/replay
overlap, headers, and all configured producer classes. It is not peak burst rate
multiplied continuously and is not an average-rate estimate. With drain capacity
at twice live ingress, a 24-hour outage needs about another 24 hours to catch up,
plus safety margin; a 24-hour `MaxAge` is therefore invalid.

For one compact one-million-host hourly installation, 24 hours of arrivals is roughly
2-4 GB logical. A retention horizon covering outage plus catch-up initially puts
that installation in roughly the 8-16 GB logical sizing band after replay/record
overhead and headroom; three replicas consume roughly 24-48 GB physical before
other streams and filesystem reserve. Actual capacity is the sum of admitted
site/agent/execution envelopes. MTR capacity is
derived from an explicit trace budget, not an assumption that every sweep target
runs MTR.

Fleet enablement requires `MaxAge` and `MaxBytes` to preserve every edge-ACKed
event through the supported outage, worst-case catch-up, and margin. Approaching
the window pages operators and stops new admission before `DiscardNew`. An
outage beyond the declared window is an explicit durability-SLO breach: affected
executions remain partial and emit a critical data-loss-risk incident; the
system never silently claims complete ingestion. Stream lag, ack-pending,
redelivery, bytes, oldest age, PubAck latency/errors, and retention risk are
mandatory telemetry.

Every capacity, retention, catch-up, storage, and PubAck-throughput calculation
is evaluated per physical stream shard using the site/agent/partition envelope
assigned to it, including worst-case hash skew and a hot execution. Stream
leaders and replicas are explicitly placed across the intended nodes and
failure domains. The deployment gate also checks the aggregate of all shards.

Pull requests are byte-bounded. Initial processor settings are 8-16 messages or
about 4 MiB raw per pull and 32-64 max ack pending, then benchmark tuned. Every
persistence consumer uses JetStream `AckExplicit`; `AckAll` is forbidden because
replicas and workers may finish deliveries out of order. A worker sends an
individual ACK only after the database transaction containing that message has
committed. If a later message commits while an earlier worker crashes, the
earlier delivery remains unacknowledged and redelivers. V1 starts with one
shared persistence durable per physical stream shard/route profile, pulled by a
bounded registry-dispatching EventWriter replica pool. Adding an output contract
does not add a durable. Any replica may receive
any `pNN`, including concurrent redelivery of the same key; correctness depends
on ledger locks, uniqueness, revision order, and assignment fences, never an
application-local exclusive owner or handoff. Additional independent downstream
projections get their own durable, but adding workers does not create one
durable, connection, or OS process per agent/execution/logical-partition tuple.
Consumer/stream RAFT-group and connection cardinality are hard deployment
limits. The persistence durable uses unlimited transient redelivery with bounded
backoff and pauses pulls during systemic database failure. It never silently
stops at a finite `MaxDeliver`; deterministic poison follows the DLQ path
instead.

A shared stream cannot select around backlog it has not yet delivered. Admission
therefore caps each site/agent/execution envelope and the installation-wide
backlog, oldest age, and interactive-job drain-delay SLO. A job that exceeds its
envelope is paused/deferred before publication. Bulk and interactive traffic use
mandatory disjoint physical streams/durables so the bounded interactive reserve
remains reachable during bulk catch-up. The stream map gives each message exactly
one durable ownership path; overlapping filtered durables are forbidden.

## Decision 7: Make persistence idempotent and bounded

Every JetStream message remains an independently decodable, costed, idempotent
unit, but persistence MAY combine multiple already validated messages into one
bounded adaptive database transaction. Interactive work flushes at its latency
bound and MAY commit one message. Sparse and bulk work groups across agents and
executions to amortize commit/WAL overhead, bounded by aggregate encoded and
resident bytes, projected write bytes, rows, message count, lock set, and a short
transaction deadline. It never crosses traffic-class or schema/projector
semantics, never becomes an execution-wide transaction, and every constituent
message retains its own delivery slot, ledger result, and post-commit explicit
ACK. A deterministic database conflict rolls the entire group back and triggers
bounded split/isolation; no constituent is ACKed until a valid subgroup commits.
Transaction admission is global to its CNPG destination. The installation-level database capacity plan
partitions measured Repo/WAL/lock headroom into explicit durable-record, sync,
control/API/Oban, and background/maintenance pools whose maxima sum to no more
than the hard destination limit. Ungoverned or database-internal work is charged
as unavailable reserve, never assumed absent.

Within the durable-record pool, one fenced resident-byte/write-byte/row/active-transaction/commit-rate
controller bounds all registered source projection, graph outbox projection, execution
reconciliation, spool-loss recovery, DLQ indexing/redrive, record rollups, and
record repair. Fixed subpools preserve recovery/reconciliation and a small bounded interactive share;
bulk cannot borrow those minimums, and interactive cannot consume the bulk floor.
Work-conserving lending outside the floors is
allowed only while every durable-record grant remains within its pool. V1 readiness
requires every in-scope writer generation to enroll. During rolling migration,
unconverted writers consume a static worst-case reservation that is released only
after they are fenced/drained. Per-consumer `max_ack_pending` is only a safety
ceiling.

Admission is two-stage. Before a pull, a worker reserves the maximum encoded/
resident `EdgeRecordV1` plus minimal transport headers and worst-case projected row/write-byte costs for
every message it requests, plus one transaction-concurrency slot for every
aggregate transaction it may execute concurrently. One sequentially split/retried
group reuses its slot only after rollback is confirmed; a parallel subgroup must
acquire another slot. A separate destination commit-rate/fsync budget bounds how
quickly slots may turn over, so grouping cannot evade WAL pressure. The worker
never pulls more messages than those reservations cover. After the decoded
record envelope, proofs, pinned contract, and cost function validate, it returns the unused worst-case delta
and holds verified resident-byte, write-byte, row, active-transaction, and commit-
rate credits through its bounded queue, commit/failure, and delivery disposition.
A message waiting
legitimately under a reservation sends JetStream in-progress heartbeats no less
frequently than one third of `AckWait`, but only until a configured bounded
processing deadline. On database unavailability, or at that deadline, EventWriter
sends NO ACK and NO TERM/poison, pauses new pulls, and lets the reservation lapse:
the message is released by AckWait expiry (redelivery), the redelivery does NOT
count toward a finite `MaxDeliver`-to-poison, and agent ownership is not restored.
It never renews heartbeats forever and never TERMs the message to poison. (The
EventWriter decision pipeline's transient-DB step states the same rule.)

Distributed grants carry a monotonically fenced generation, expiry, and maximum
transaction deadline. Old grants remain charged until surrendered or expired;
scale-out/rebalance cannot reuse their capacity concurrently, and a worker does
not admit work unless its lease outlives the transaction deadline. If the
allocator is unavailable, no new pull is admitted. Crash reclamation waits for
expiry and confirmed database session cancellation/death; DB-side statement and
transaction timeouts never exceed the grant deadline. Immediately before commit,
the transaction rechecks the current grant generation/expiry and rolls back if
fenced. If cancellation/session death cannot be confirmed, the worst-case old
transaction remains charged. Static quotas are
acceptable only when their configured sum, including rolling overlap, is within
the same hard total. Fair suballocation prevents a hot site/agent/producer/run
or MTR workload from consuming every general credit, while the reserved
recovery/control pool remains available.

Within those credits, projection is:

1. Insert or lock both a delivery binding keyed by the STABLE logical slot
   `edge_slot = (network_scope_id, authenticated_agent_id, spool_id, sequence)`
   -- the authenticated AGENT owns the spool (a key component) and the PRODUCER is
   semantic provenance (a stored value, NOT part of the slot key) -- a scoped,
   independently unique delivery id derived from those immutable coordinates
   (the gateway-created opaque `Sr-Edge-Delivery-Id`), NOT by the physical
   JetStream stream/sequence (which changes when a re-encoded record gets a new
   Msg-Id/sequence) -- and an ingest-ledger row keyed ONLY by network scope and
   semantic event ID, partitioned by a retention bucket deterministically
   derived from the event ID (its UUIDv7 timestamp). The
   ledger STORES the attested origin principal, exact output-contract bundle,
   authenticated agent, and payload kind as immutably compared values, never as
   key components. The delivery binding STORES `record_sha256` as the compared
   physical value and the JetStream stream/sequence plus event ID as
   provenance/comparison values, never copying spool coordinates into semantic
   headers; a second frame on the same slot with a different `record_sha256`
   therefore hits the SAME binding row and is a transport-integrity conflict, not
   a new row. The ledger stores
   record/payload checksums, encoded/projected-write byte counts, cost-model
   version, immutable `semantic_envelope_sha256`, expected/projected record counts,
   and commit state (not the payload body).
2. If the ledger already has a committed row for `(network_scope_id, event_id)`
   whose stored `semantic_envelope_sha256` MATCHES, return success without
   re-applying side effects (even if `record_sha256`/bytes differ). The same event
   ID whose stored `semantic_envelope_sha256` DIFFERS is `EVENT_ID_CONFLICT`
   poison; a different `record_sha256`/body layout with an identical
   `semantic_envelope_sha256` is a replay, not a conflict.
3. Bulk insert/upsert domain rows, current-state changes, immutable per-shard
   execution evidence, deterministic OCSF events, required low-cardinality
   projections, and any required derived-view outbox rows. Do not lock/update
   one parent execution-summary row per batch.
4. Mark the ledger entry committed with actual row counts.
5. Commit the bounded message group, then explicitly ACK each constituent
   JetStream delivery; never use cumulative `AckAll` semantics.

Before SQL, the projector canonical-sorts every overlapping identity/current-
state/summary key and acquires tables and rows in one documented global order.
Bulk `INSERT ... ON CONFLICT` input follows that same order. This prevents two
legal batches containing the same devices in reverse order from turning bounded
concurrency into a deadlock/retry storm.

Every address-derived identity starts with the authoritative `network_scope_id`.
Stable keys and fencing rules include:

- raw sweep host mode fragment: trusted scheduler identity time + network scope +
  agent + execution ID + execution shard + assignment epoch + canonical address
  + mode + mode revision;
- reconciled per-agent execution host: network scope + agent + execution ID + execution
  shard + canonical target, selecting the scheduler-authoritative assignment and
  latest revision independently per mode;
- MTR trace: UUIDv7-derived trace identity time + network scope + stable
  `trace_id`, with observation time and trace content immutably bound to that
  identity;
- MTR hop: network scope + trace key + hop number + path-variant identity;
- OCSF event: deterministic ID from network scope plus stable domain-record identity;
- delivery slot: the frozen `edge_slot` = network scope + authenticated agent
  + spool ID + sequence (the partition/retention bucket is DERIVED from this tuple
  plus the spool generation epoch, and is NOT part of the slot KEY),
  immutably bound to event ID, semantic digest, and the exact-record checksum
  `record_sha256`; a later frame on the same slot with a different `record_sha256`
  is a transport-integrity violation;
- ingest ledger: retention bucket (derived from the event ID) + network scope +
  event ID ONLY, storing authenticated agent and payload kind as immutably
  compared values;
- sweep batch slot: network scope + execution ID + execution shard + assignment epoch
  + batch sequence, immutably bound to event ID, `semantic_envelope_sha256`
  (committing `payload_sha256`), host/mode counts, and projected rows;
- agent terminal slot: network scope + execution ID + execution shard + assignment
  epoch, immutably bound to terminal kind, event ID, closed batch interval,
  counts, outcomes, and the versioned MTR COMPLETION digest. (There is no MTR range
  root: `range_root_sha256` is RETIRED, tag 20 reserved.)

Governed cluster-local publishers that reach the same authoritative
record/projector contract through a direct JetStream publisher use a
domain-separated SERVICE-INGRESS slot variant, `service_slot =
(network_scope_id, authenticated_service_id, publication_lane_id,
publication_sequence)`, carrying its OWN domain tag. It plays the identical role as
`edge_slot` in the delivery id, transport provenance, partition/retention bucket,
and SQL uniqueness; service-ingress v1 is FRESH-only, so a `service_slot` takes part
in NO delivery grant (renewal/rollover). Its retention bucket derives from the tuple plus
the publication epoch.

Replaying an equal sweep batch-slot binding is harmless. If two different
bindings claim one slot, the first authenticated binding that commits remains
immutable forensic/domain state; a later conflicting claim is poison and never
overwrites or merges with it. The attempt is marked `integrity_failed`, cannot
reconcile complete, and its range is scheduled under a new fenced epoch to
repair authoritative current state/counts. No order-independence guarantee is
made between two mutually protocol-invalid values. The terminal sequence
reconciler reads only committed non-conflicting slots from authoritative
attempts.
Likewise, reusing one network-scope-scoped `trace_id` with a different observation time
or trace content is poison rather than a second historical trace.
Reusing one delivery slot for different semantics is also poison, even though
its changed broker publication ID reaches JetStream. Recovery may bind the same
semantic event to a new slot; the semantic ledger then deduplicates it normally.

The first authenticated agent-terminal binding is immutable. A conflicting
terminal or any data batch outside its closed interval makes the attempt
`integrity_failed`, excludes it from authoritative reconciliation, and triggers
fenced range repair regardless of whether data or terminal arrived first.
Scheduler-authored lost/expired/superseded state occupies a separate authoritative
assignment-state slot and never masquerades as agent evidence.

Sweep and MTR identity are partition-local by construction rather than duplicated
into a permanent non-hypertable row per observation. Raw sweep history uses an
immutable `identity_time` resolved from the scheduler-owned execution epoch; the
projector rejects any agent-supplied alternative. Its unique key includes
`identity_time`, network scope, agent, execution, shard, assignment epoch,
canonical address, mode, and mode revision. The row binds canonical observation
time and semantic digest, so every replay or conflicting binding for one logical
observation reaches the same partition. Long-lived/continuous work rotates
bounded scheduler epochs instead of keeping one identity partition open forever.

V1 MTR trace IDs are RFC 9562 UUIDv7 values allocated and durably recorded before
probing. `trace_identity_time` is derived from the UUIDv7 timestamp and must fall
inside the signed collection interval plus clock tolerance; the trace's
authoritative per-hop observation and completion time(s) MUST also fall within that
signed collection interval (plus tolerance), with `trace_identity_time` validated
for consistency rather than being the sole time checked.
`mtr_traces` uniquely binds `(trace_identity_time, network_scope_id, trace_id)` to
authenticated source/context, canonical target, observation time, and semantic
digest; `mtr_hops` references that physical key. A summary that precedes its trace
may create a bounded partitioned expectation row, but the row is consumed or
reduced to terminal reconciliation state when the trace resolves. V1 does not
retain a permanent `sweep_observation_identity` or `mtr_trace_identity` side row
for every completed observation.

The scheduler issues a monotonically increasing `assignment_epoch` and signed
collection capability whenever a shard or target range moves to another agent.
The collection capability, not the scalar epoch, proves that the authenticated
agent was permitted to probe the bounded range until its lease/fence generation;
a delivery capability can only drain immutable bytes as defined above.
Reassignment fences the old epoch before the replacement owns its range.
Already durable late data from an older epoch remains auditable but cannot
change reconciled counts, current state, or terminal status after the fence.
The epoch is not part of the partition hash, so related data retains locality;
reconciliation still does not depend on arrival order.

Execution totals are reconciled from unique committed observations, the
immutable execution plan, and authoritative terminal state/evidence for every
assignment attempt. They are not blindly incremented on every delivery. Current
device state is updated only by a newer per-agent/mode observation. The
total-order key is
the bounded per-host probe-completion timestamp, configured source priority,
execution ID, authoritative assignment epoch, mode revision, and event ID;
arrival or batch-flush time is never used. Agent clocks outside the configured
original signed source-authorization interval (plus bounded tolerance and any
attested session clock offset) are quarantined rather than allowed to pin future
state. Gateway receipt time is delivery-latency metadata and a one-sided future
sanity check, never a symmetric age window: an old frame legitimately retained
through the supported spool/outage horizon remains valid when its observation
time fits its original collection authority. Equal domain keys with equal
content are replay; equal keys with different content are poison.

Derived events do not depend on which concurrent projector won first. Every
authoritative observation gets one deterministic immutable OCSF observation
event. Lifecycle transition events are produced separately by an event-time
reconciler that sorts authoritative observations by the same total order and
advances only through a closed execution/time-epoch watermark. Before closure,
state is explicitly provisional. Data older than a finalized watermark follows
a versioned correction/retraction policy with deterministic IDs; it cannot
silently create a different alert/event set based on broker arrival order. A
narrow raw observation history uses
time-partitioned retention; current state and execution summaries are retained
separately; longer-term UI/SRQL views use rollups.

Parent execution totals/state are refreshed from per-shard committed ranges by
a separately bounded, coalescing reconciler. Every evidence/terminal transaction
inserts an append-only reconcile-work event keyed by the source ledger event and
carrying the immutable traffic class; it never updates one `(network_scope,
execution)` dirty tuple. A fixed number of class-separated reconcile queue
partitions hash trusted network-scope/execution identity. Fenced expiring leases
give one worker at a time a bounded batch from a queue partition, and the
interactive queues retain an unborrowable claim/credit floor during maximum bulk
catch-up. The
worker groups many work events per execution, recomputes from authoritative
committed ranges/attempt state, and atomically stores the parent summary and
marks the claimed work processed. New evidence remains as later work. A bounded
anti-entropy scan recreates missing work from append-only evidence. This keeps
both the parent row and a substitute global dirty row off the per-message hot
path, collapses bursts into coalesced updates, and survives a crash after
evidence commit or during summary update.

Initial hard transaction caps match the 10,000 total sweep-projection-row and
5,000 MTR-row message budgets; normal builders target materially less. Both caps
are tuned downward with real CNPG/WAL/index measurements if needed. An
execution-wide transaction is explicitly forbidden.

Malformed or permanently incompatible consumer events are published, including
original bytes and error metadata, to the mapped DLQ partition whose message
limit safely exceeds the source message plus bounded diagnostics; its PubAck is
required before the source delivery is terminated. Consumer poison uses a stable
ID from network scope, source stream/sequence, source checksum, and error class. A
gateway rejection before primary publication instead uses trusted network-scope/agent,
spool ID/sequence, a safe full-frame fingerprint or semantic digest, and rejection
class. Both survive an ambiguous DLQ PubAck while the gateway stays stateless.
DLQ credentials, retention, access auditing, and encryption protect raw topology
data. Transient database errors leave the message PENDING/redeliverable with no ACK and no TERM/poison; the consumer pauses new pulls and the reservation lapses at the bounded processing deadline via AckWait expiry (redelivery, not counted toward a finite MaxDeliver), and agent ownership is not restored.

The bounded canonical DLQ wrapper preserves the exact immutable `EdgeRecordV1`
bytes and digest, bounded source delivery/proof audit, original source stream/
sequence, traffic class, and body checksum alongside raw body and error metadata. Gateway
rejections preserve the maximum safely validated subset plus a full-frame
fingerprint. Redrive re-verifies that provenance and generates only fresh
transport-minimal delivery/map headers; it never reconstructs authority from
broker metadata or untrusted domain-body claims.

An event using a valid advertised newer schema for which the mapped consumer is
not ready is a deployment-readiness/systemic failure, not permanent poison:
pulls/admission pause. After a bad decoder/schema rollout is repaired, an
operator-authorized deployment-local redrive may republish retained raw bytes with
their original trusted semantic identity through the current stream map. Each
redrive has a durable synthetic `dlq-redrive` spool ID/sequence and an operator/
scheduler capability bound to the immutable DLQ record; those new delivery
coordinates create a new publication ID and delivery-slot binding even inside the
original broker duplicate window. Original spool/stream coordinates remain
provenance only. Redrive is rate/credit limited, fully audited, requires exact
error cohort selection, and relies on the ordinary semantic ledger for
idempotency; it cannot rewrite network scope, authorization, or content. Source TERM,
redrive, and final audited deletion are distinct states.

MTR persistence also maintains an expected binding for every trace referenced by
a sweep or ad-hoc summary: `(network scope, authenticated agent, source/authorization
context, execution+shard+epoch or check/command, canonical target/host,
trace_id)`. Summary-first and trace-first arrival use the same binding. A trace
becomes `projected` only when its immutable identity/content matches all expected
fields; reusing an existing network-scope trace ID for another target/context is
`integrity_failed`/quarantined and cannot satisfy a terminal trace digest.
Reachability projection may complete first, but the execution exposes MTR
`pending`, `projected`, `failed`, `missing`, or `quarantined` counts and is not
fully reconciled until its authoritative plan/attempt state and terminal
evidence's expected binding count/digest are satisfied, the affected range's WHOLE
window is reassigned and replayed, or every missing trace has an explicit terminal
disposition. There is no partial-remainder retry input in v1.

The source MTR transaction also inserts an idempotent graph-outbox row keyed by
`(network_scope_id, trace_id, graph_schema_version)` before the JetStream delivery is
ACKed. The outbox stores the bounded immutable graph-projection input (or a
content-addressed non-hypertable payload) transactionally; it is never only a
pointer to trace/hop chunks that retention may drop. Raw chunks may retire once
every unresolved projection input is independently durable, without pinning a
large Timescale chunk for one failed row. Each row preserves the immutable
traffic class.

Graph projection is a two-stage append-only fold rather than concurrent direct
updates from arbitrary trace workers. A bounded normalizer transaction expands a
trace outbox payload into deterministic vertex-observation and edge-observation
tasks, stores the expected task count/digest, and marks the parent `expanded` in
the same transaction. Every topology task is keyed by source trace plus stable
network-scope-safe topology identity and carries an immutable
`graph_owner_map_version`, `owner_shard = hash_version(topology_identity) mod K`,
source class, monotonic observation order, and all immutable projection input.
`K` and the hash function are immutable within one graph owner-map/schema version.
Endpoint vertex tasks commit before dependent edge tasks become eligible.

Exactly one fenced worker lease owns an `(owner_map_version, owner_shard)`
generation at a time.
Class-aware subqueues and an unborrowable interactive claim/credit floor prevent
bulk work from delaying interactive topology indefinitely. The worker claims a
bounded class-fair batch, coalesces all observations for the same vertex or edge
to the deterministic newest/aggregate value, performs set-oriented or
`UNWIND`-style AGE mutations, advances the relational watermark, and marks the
represented tasks projected in one PostgreSQL transaction. Thus thousands of
traces sharing a backbone hop or edge cause one coalesced owner update per fold
window rather than cross-worker lock contention. A parent becomes `projected`
only after its expected task digest/count is fully resolved. It never issues one
transaction/Cypher call per hop.

Graph failure rolls the owner transaction back and leaves its tasks pending with
observable attempts/error/age; it is never rescued as success, and replay of the
already-committed source event cannot bypass the existing outbox/tasks. A repair
audit finds committed traces missing an outbox, expanded parents missing tasks,
and parents whose task completion does not match their expected digest. Changing
`K` or the hash function requires a versioned stop-expand/fence/drain barrier:
normalization pauses, every old task resolves or is atomically migrated with its
payload/watermark under a new owner fence, old leases are revoked, and only then
does the new map accept tasks. Owner-map history remains through repair, prune,
and rollback horizons; old and new owners never mutate one topology identity
concurrently.

Graph identity is network-scope-safe and monotonic. HopNode identity starts with
network scope plus canonical address; an existing Device is reused only inside
that scope. `MTR_PATH` identity includes network scope, agent, protocol, ordered endpoint identities,
and path-variant dimension. RTT/loss/hostname/ASN/last-observed properties update
only when `(observed_at, trace_id)` is newer than the stored order; late older
traces remain historical and never move `last_observed_at` backward. Queries,
TTL pruning, and orphan cleanup are network-scope-scoped. A compact relational
`graph_edge_watermark` is uniquely keyed only by the same scope-safe edge
identity and stores its current owner-map version/shard/fence plus maximum applied
order and prune tombstone through the full source replay/DLQ-
redrive horizon. Advancing the prune tombstone and deleting the AGE edge occur in
one owner-fenced PostgreSQL transaction. An owner-map migration changes the
stored owner only under that row's old/new fence barrier. TTL deletion uses the
stored current owner as projection. TTL deletion of an
AGE edge therefore cannot let a delayed old
outbox recreate it; an already-expired observation is marked projected-expired
without recreating topology. Graph-outbox lag/backlog has a
budget and can pause new MTR admission before derived topology falls outside its
declared freshness window. Fleet enablement requires graph drain throughput
above admitted live MTR edge rate plus the catch-up margin, including contention
on common backbone edges; graph-specific lock/WAL cost, lag, and freshness are
measured independently from relational trace ingest.

Retention defaults and safe bounds come from these benchmarks, but the existing
operator-managed MTR retention setting remains authoritative within them.
Migrations/control-plane reconciliation own Timescale retention/compression DDL;
EventWriter only writes rows and telemetry and never creates or alters policies.

Correctness replay has a finite configured horizon; metadata is not an unbounded
shadow database. The retirement bucket derivation is split by identity domain.
Ingest ledgers, expectations, and correlations are assigned a trusted retirement
bucket derived from the validated UUIDv7 event ID. Ordinary
delivery/terminal/batch slots are assigned their retirement bucket from their
IMMUTABLE SLOT COORDINATES, NOT from the event ID -- otherwise reusing one slot
with a different event ID would select a different partition and evade the
delivery-slot binding. Each such non-ledger slot partition key SHALL be
`(ordered_time_bucket, hash_subshard)` so whole old windows drop wholesale by range:

- `ordered_time_bucket` is the slot's epoch coordinate floored to a fixed retention
  window (one window per configured retention granularity). It is CHRONOLOGICALLY
  ORDERED, so a whole expired window is dropped by a single range `DROP`/detach, never a
  hash scan.
- `hash_subshard` is the low N bits of `SHA-256(slot-tuple)` (fixed width, e.g. 8 bits ->
  256 subshards), spreading write load WITHIN a window.

A hash of `epoch || slot` truncated to a single fixed bucket would mix epochs forever and
could never be dropped chronologically, so it is NOT used. The epoch coordinate is carried
on the slot binding or deterministically derivable, and the tuple hashed for the subshard
is fixed PER SLOT TYPE:

- delivery slot: epoch = spool generation epoch; subshard = `hash(edge_slot)`.
- sweep-batch slot: epoch = assignment epoch; subshard = `hash(scope, execution, shard)`.
- agent-terminal slot: epoch = assignment epoch; subshard = `hash(scope, execution, shard)`.
- service-ingress slot: epoch = publication epoch; subshard = `hash(service_slot)`.
- event ledger: KEEPS its `event_id` UUIDv7-timestamp window (already chronological); no
  change.

Each bucket is checked against collection authority. That
check validates both the UUIDv7 identity time AND the authoritative body
observation/event time, which must be consistent within tolerance.
After agent-spool, JetStream/AckWait/redelivery,
repair, compatible rollback, and integrity-audit watermarks pass that bucket,
ordinary metadata is retired by whole partition detach/drop, not row-by-row GC.
Long-retained current state, execution summaries, rollups, or historical query
rows do not by themselves pin ordinary correctness metadata after their immutable
projection can no longer produce side effects.

Before ordinary metadata for an unresolved DLQ, recovery, rollback, graph repair,
or other exceptional item retires, the system atomically persists a bounded
`correctness_hold` containing semantic identity, first accepted
`semantic_envelope_sha256`/`payload_sha256`,
original traffic class, source catalog locator, state, and domain-replay deadline.
It also retains the complete bounded input needed to finish the unresolved work,
either inline or through a checksummed content-addressed payload whose reference
and lifecycle are owned by the hold. Before dropping an ordinary partition, the
system atomically copies an inline graph/outbox/task payload into held storage or
pins its existing content-addressed payload; a digest-only hold is insufficient.
Redrive below the ordinary acceptance watermark requires that exact hold. After
the domain-replay deadline, resolution is audit/partial/recollection-only and
cannot rehydrate expired raw history or mutate current state. A hold is removed
only after final resolution and its audit horizon close; finite class-separated
DLQ/recovery/repair capacities and their admission circuits bound the hold set.

A non-held delivery below the durable acceptance watermark terminates as
`replay_horizon_expired` after one stable bounded audit record and cannot recreate
domain or correctness rows. The live-state invariant is ordinary metadata no
greater than admitted events inside the replay horizon plus holds no greater than
configured exceptional capacity. If watermark progress, partition retirement,
or hold capacity cannot maintain that invariant, the scheduler stops new scan
admission before the hard metadata row/index-byte/held-payload budget is exceeded.

Immutable execution plans/ranges, authoritative assignment/fence records,
capability signing metadata, and retired verification keys remain available for
every event still inside the accepted replay horizon or represented by a hold.
Pending graph/recovery work remains held rather than pinning an ordinary time
partition. Capacity planning specifies metadata bucket width, maximum live
partitions, row/index bytes, insert rate, partition-retirement rate, hold limit,
and a long-horizon sawtooth/plateau model; linear steady-state growth fails
readiness.
## Grammar and version inventory — moved

The grammar/version inventory (Decision 8's ABI material) moved to the
`freeze-edge-record-v1-abi` change. This change consumes those frozen grammars and
MUST NOT restate their versions, domains, or field orders.

Raw `proto.Marshal` output MUST NOT be a runtime-neutral semantic, signing,
authorization, merge, or logical-content grammar, and there is no decode ->
re-encode -> byte-compare admission and no required whole-record byte equality:
protobuf has no canonical wire form. Protobuf encoding is legitimate wherever the
design produces a PHYSICAL artifact -- the producer adapter's one domain-body
encode, the sink's one `EdgeRecordV1` encode, and each `EdgeDeliveryFrameV1`
delivery-frame encode -- plus transport / `proto.Size` / fixtures. Those physical
protobuf artifacts MAY be hashed as explicitly-designated content-addressed
artifacts (`record_sha256` over the exact record bytes, `payload_sha256` over the
exact encoded body), and their NAMED digests MAY participate in transcripts (the
semantic-envelope transcript commits `payload_sha256`). What is forbidden is
placing raw marshalled bytes INSIDE the semantic-envelope, capability-signing, or
plan/range/recovery/completion preimages. The sink encodes once and fsyncs those
exact bytes; the spool, sender, gateway, JetStream, and record DLQ preserve them
unchanged; gateway and EventWriter decode and hash but never normalize, reorder,
or re-encode them.

### Ledger replay and conflict outcomes

Every output contract defines deterministic domain identity, revision/merge
semantics, and authoritative-versus-derived status. A grant forbids a producer
from emitting the same fact simultaneously as typed output, extension output,
`MetricBatch`, OCSF, plugin-result JSON, or a lossy add-on copy. The agent does
not publish a second generic representation of every host, port, MTR hop,
inventory object, or plugin metric. The canonical domain stream is subscribable
by persistence, anomaly/causal, and other real-time consumers.

The persistence projector may write required low-cardinality execution/scanner
metrics in the same transaction. A separate stateless normalizer may publish a
derived `MetricBatch` only if an existing consumer cannot read the domain event;
that publisher must be unique, idempotent, correlated to the source event, and
must not recreate per-host/per-hop duplication.

Already-accepted pre-cutover executions may finish and drain their existing
sweep/MTR metric projection. A v1 execution never emits that duplicate
representation; its required low-cardinality metrics are derived from the
canonical event. Canary comparison uses separate hard-cut cohorts or a
non-writing shadow, never two authoritative writes for one execution. The old
projection is removed from the agent after its bounded backlog drains and parity
audits pass.

## Decision 9: Keep blob and media bytes out of the durable record plane

Bounded sweep batches, MTR traces, metrics, lifecycle events, inventory pages,
and approved extension records stay in JetStream. They are record-oriented and
must be available to streaming consumers. The record plane may carry an
immutable artifact reference and its bounded lifecycle/audit events, but not the
artifact bytes.

This v1 does not add an upload path or object lifecycle. Packet captures, raw
command archives, camera/video data, large files, and other indivisible objects
require a separate proposal covering installation-bound create-only keys,
resumable idempotent upload, durability acknowledgement, manifest publication,
orphan GC, reference-aware deletion, authorization, and a pluggable object
backend. An oversize producer record is a `permanent_rejection` (NOT quarantined --
quarantine is reserved for admitted poison); it is never silently diverted into Object
Store or split without a contract-defined bounded page/run protocol.

## Decision 10: Treat "zero-copy" as encode/decode minimization

Literal end-to-end zero-copy is impossible across the required process and
durability boundaries. The useful contract is:

- no full-run materialization or reassembly;
- one domain-body encode at the producer adapter and one
  `EdgeRecordV1` encode at the agent sink;
- one small delivery-wrapper encode per spool placement; rollover or renewed
  delivery authority rewraps unchanged record bytes and never re-encodes the
  semantic record;
- one unavoidable bounded Wasm guest-to-host copy, without base64 or JSON
  wrapping of the submission (contract-payload) bytes;
- gRPC framing, TLS, socket buffers, BEAM protobuf terms, the NATS client, broker
  replication, and PostgreSQL WAL may each require bounded copies; the design
  does not claim otherwise;
- gateway retains and forwards the same `record_bytes` binary after bounded
  envelope decode, without semantic or domain re-encode;
- EventWriter decodes `EdgeRecordV1` and its domain body once per consumer;
- bounded bulk database construction;
- no JSON map tree and no duplicate per-host, per-hop, inventory-page, or plugin
  telemetry serialization.

Go `MarshalAppend`, buffer pools, compression, and custom allocators are later
optimizations gated by profiles. They must not complicate the correctness path
before allocation data shows a remaining bottleneck.

## Decision 11: Recovery attribution is captured at append time and bound to the record

v2 requires a loss manifest whose pages carry attribution -- as the ordered
`classification_spans` list that task 1.6a freezes, replacing the candidate
`lost_ranges` + `EdgeAffectedScopeV1` pair -- so a recovery
manifest must be ATTRIBUTABLE to the producers whose output was lost. The pre-v2
rollover journal recorded lost sequence RANGES only, and no downstream component
can supply the missing provenance after the fact:

- the GATEWAY never observed the records that were lost locally;
- the SENDER cannot own manifest identity, because that identity must survive
  sender crashes and retries;
- `record_bytes` cannot be the only home, because the corruption that triggers
  recovery is exactly what makes those bytes undecodable.

Attribution is therefore captured where the authority exists — at spool append,
from the producer sink — and stored as a separately checksummed
sequence-to-attribution relation that survives loss of the records it describes.

### Why the attribution must be BOUND, not merely adjacent

An index stored beside the records is not sufficient. After partial corruption, a
truncated tail, or a mis-replayed compaction, an adjacent index can pair one
record's provenance with another's sequence. The manifest would then validate
while attributing loss to the wrong authority — a silent integrity failure that is
worse than declaring the span unknown.

The spool therefore verifies SEMANTIC JOINS first, then commits the physical
binding. The joins prove the provenance came from THIS record: attribution
`contract_bundle_sha256` against the record's `EdgeOutputContractRef` bundle
digest; `producer_assignment_id`/`run_id`/`run_shard` against its
`EdgeProducerContext`; `authority_epoch` against EACH APPLICABLE claim;
`production_scope_id` + `scope_sha256` against the PRODUCTION scope ONLY, and
`source_scope_id` + `source_scope_sha256` against the SOURCE scope ONLY WHEN a
source authorization is present -- those are DIFFERENT values in the canonical
accepted record, so one member cannot serve both, and IDs travel with digests
because the wire signs and validates each independently; the SOURCE IDENTITY
(kind, `context_id`, `source_scope_id`, `source_scope_sha256`, or their joint
absence) against the record's signed source authorization. CLASSIFICATION and
source presence are INDEPENDENT axes: `ATTRIBUTED_PASSIVE` means "no produced
target range", NOT "no source authorization", and the source join follows PRESENCE
alone. Correlation is checked against the operands
the body actually carries, per payload contract and correlation variant -- NOT a
`run_id == context_id == execution_id` equality, which the accepted golden vectors
already falsify; and, for ACTIVE attribution, `range_sha256` against the signed
source range or the frozen contract-owned derivation. Only then does it commit the
physical binding over the EXACT local-binding transcript: the generation's TRUST
NAMESPACE (`network_scope_id` and authenticated agent identity -- neither lane nor
spool generation subsumes them), lane and spool/generation identity, sequence,
`event_id`, `record_sha256`, and the complete attribution tuple including both
logical scope IDs.

Physical binding alone is forgeable: a sink can attach record B's provenance to
record A and compute a perfectly valid binding over A. The joins are what make the
binding mean "this provenance came from this record".

The two failure times are DIFFERENT outcomes and must not be conflated:

- APPEND-TIME semantic mismatch -> PERMANENT REFUSAL. The append never becomes
  durable, so there is no loss to attribute and nothing is stored.
- LATER CORRUPTION of a binding that verified at append time -> UNATTRIBUTABLE.
  The append WAS acknowledged, so the span must be reported, and the reason
  records that its binding no longer verifies.

### Why "unattributable" must exist on the wire

Recovery is precisely the situation in which evidence may be missing. A contract
that can express only "attributed" leaves a producer two bad options: fabricate an
affected scope, which is a correctness violation, or emit a manifest its own
validators reject, which makes recovery impossible. So unattributable is a
first-class, explicitly encoded state carrying its reason, and manifest validation
accepts it without demanding a covering scope.

### Why distinct-key bounds alone do not bound recovery

Bounding the number of distinct attribution keys per segment does not bound the
manifest. Attribution alternating between two keys stays within any distinct-key
bound while producing one RUN per record, so a corrupt segment's manifest would
grow with record count and could exceed the recovery grammar's page and byte
ceilings — making the loss unreportable at exactly the moment it must be reported.
Segments are therefore bounded on distinct keys, on runs, and on resulting
manifest size, and rotate on whichever binds first.

### Why reclamation needs a reserved budget

"Do not reclaim until the terminal outcome is durably recorded" is correct but, as
a blanket rule, self-defeating: a full spool awaiting terminal outcomes has no room
to write the manifest that produces them, and recovery deadlocks against its own
precondition. The spool therefore reserves a bounded scratch budget, excluded from
producer admission and sized for the AGGREGATE of what a recovery must durably
write -- destination segment, attribution sidecar, both journal copies,
manifest/tombstone pages, the old->new mapping, and filesystem metadata --
multiplied by the bounded number of concurrent recoveries. Sizing it for "one
corrupt segment" counts only the input and none of the artifacts.

The releasable thing is EVIDENCE, not bytes -- but journalling a manifest is NOT
by itself that evidence. A journalled manifest that has not been PubAcked is not
yet proof the loss was reportable, so releasing on it can destroy the only intact
record of an acknowledged append. Source bytes may be released only under the
coverage proof: every unreclaimed ALLOCATED sequence in
`(durable_local_reclaim_watermark, sequence_high_water]` -- not merely every
committed slot, since a markerless allocated sequence is exactly what restart
calls ambiguous -- either committed and sender-visible at the
destination (wrapper, coordinates, rebound attribution, old->new mapping,
high-water, and directory metadata all covered by the destination's own commit
evidence), or inside a frozen loss span whose required recovery pages have PubAcked
AND whose covered sequences are each backed by durable per-sequence loss evidence
whose journaled classification matches the span's complete oneof body. When only
recovery-critical work remains, producer appends are refused
rather than un-covered evidence reclaimed.

### Ownership

```
producer sink        -> creates immutable EdgeRecordV1 + RecoveryAttribution
spool                -> atomically persists record bytes AND bound, corruption-
                        independent attribution; detects corruption; retains
                        attribution and copy evidence
recovery coordinator -> freezes, pages, hashes, journals manifest/tombstone
                        (NOT "signs": no agent-signature ABI exists; integrity is
                        the journalled content-addressed chain, authenticity is the
                        authenticated session + capability model)
recovery sender      -> transmits already-frozen recovery records
gateway              -> validates, stamps transport provenance, publishes
                        unchanged bytes
EventWriter          -> applies only a complete validated manifest
```

Each boundary is placed where the authority and the evidence coexist. Moving any
step outward — letting the sender author manifests, or the gateway assemble
them — puts the decision somewhere that cannot see what it is deciding about.

## Failure Semantics

| Failure | Required behavior |
|---|---|
| Agent crash | Replay the fsynced spool with original IDs/sequences; if terminal evidence never arrives, the scheduler terminalizes/fences the attempt and REASSIGNS THE WHOLE RANGE WINDOW. v1 cannot represent a sparse remainder -- an assignment's MTR expectation is one contiguous plan-global window -- so a retry replays the complete window. |
| Gateway/link failure before PubAck | Do not ACK; reconnect and replay. |
| PubAck succeeds but edge ACK is lost | Replay same event ID; broker/DB deduplicate. |
| JetStream unavailable or full | Stop ACK progress; retain at agent and apply backpressure. |
| Agent spool high-water | Defer new/lower-priority producer work and scans and alert; never overwrite unacked data. |
| Agent spool `ENOSPC`/`EIO` | Stop new durable production/probes, preserve or recover the bounded window, expose delivery failure, and retry or abort the fenced run/range without claiming durability. |
| Producer times out after possible fsync | Retain the atomic producer-key binding; receipt lookup/retry returns the original identity and same-key/different-body is rejected. |
| Wasm ignores `WOULD_BLOCK` | Pause/fuel-limit or terminate that producer without dropping accepted records or consuming another producer's reserve. |
| Native add-on disconnects around local ACK | Resume under a fresh fenced session nonce from the last cumulative durable watermark; stable producer keys absorb uncertain retransmission. |
| Output contract is unknown or deployment-not-ready | Grant no new run and retain ownership at the producer; do not classify a rollout mismatch as ordinary poison. |
| Output contract is security-revoked | Stop new output and hold/quarantine matching backlog until an operator selects a safe historical/fixed bundle or waives it. |
| Inventory terminal is incomplete, conflicting, stale, or lacks completeness proof | Keep pages staged/upsert-only, preserve the current snapshot, poison conflicts, and garbage-collect abandoned staging only after its repair horizon. |
| Corrupt committed spool sequence | PubAck a journalled, content-addressed loss tombstone (NOT agent-signed; no agent-signature ABI exists) through the recovery lane, abandon the old spool, re-enqueue recoverable later events with stable semantic IDs, and mark lost coverage partial/retriable. |
| Collection capability expires with backlog | Stop new probes; obtain event/checksum-bound delivery-only authority or leave the frame unresolved, then apply scheduler fencing at projection. |
| Consumer or database failure | No ACK and no TERM/poison; pause new pulls; the reservation lapses at the bounded processing deadline via AckWait expiry (redelivery, not counted toward a finite MaxDeliver); never renew heartbeats forever; agent ownership not restored. |
| AGE graph projection failure | Keep the atomically created outbox pending, retry idempotently, expose lag/error, and never treat a rescued exception as success. |
| Poison payload | PubAck original bytes to DLQ, then terminate source delivery. |
| Gateway rejects a bounded frame | PubAck safe audit metadata to the deployment DLQ, return a rejected disposition, and retain raw bytes in agent quarantine. |
| Gateway restart | Reconnect; the stateless gateway has no acknowledged-only buffer. |
| Missing execution batch/shard | Keep execution partial and expose missing ranges. |
| Missing correlated MTR trace | Keep the MTR substate pending/missing/failed and do not report full reconciliation. |
| Retention window exceeded | Declare a durability-SLO breach and affected executions partial; never hide expiry as success. |
| Core rollback with proto backlog | Forbidden until the backlog and agent spools are drained or compatible consumers remain. |

## Performance and Reliability Gates

The implementation does not fleet-enable until it proves:

- zero acknowledged-message loss through gateway/core restarts and a configured
  24-hour core/consumer outage followed by worst-case catch-up, including events
  that begin near the configured `MaxAge` boundary;
- zero duplicate domain/OCSF/MTR rows and exact execution counts under at least
  five forced redeliveries;
- detection and quarantine of a semantic event ID reused with changed bytes
  inside and outside the JetStream duplicate window;
- p99 agent-to-JetStream durability below 2 seconds at the expected burst;
- p99 observation-to-queryable below 30 seconds at the expected burst;
- a separately declared end-to-end interactive durability, queryability,
  reconciliation/terminal, and graph-freshness SLO that remains bounded while
  bulk source streams, reconcile queues, graph outboxes, DLQ, and database
  writers operate at maximum admitted catch-up;
- a one-million-host, ten-port result drains in at most 6 minutes;
- at least 10,000 host observations/second aggregate on the documented reference
  deployment and backlog drain capacity at least twice live ingress;
- a measured MTR target of at least 1,000 traces/second or 20,000 hop rows/second
  in replay before production trace budgets are set;
- result serialization/delivery memory below 256 MiB and independent of total
  scan size; no full-scan result slice or JSON tree and no scheduled,
  sweep-profile, ad-hoc, or on-demand MTR run/interval result collection;
- bounded BEAM mailboxes and queues by bytes as well as item count;
- measured retained gateway memory remains bounded with maximum headers,
  compression, delayed PubAcks, and a zero-window bulk connection while
  interactive and recovery traffic continue within their SLOs;
- bounded global CNPG transaction/row/byte credits with stable Repo pool checkout
  latency, lock waits, WAL/fsync latency, and no timeout/redelivery storm while
  sync, control/API/Oban, and background/maintenance pools are concurrently busy;
- no reverse-order deadlock under concurrent source, graph, reconcile, recovery,
  DLQ, and repair writers using the canonical lock order;
- worst-case timer-fragmented traffic from 1,000 low-rate agents meets ingest and
  interactive-latency gates without one commit fsync per message; record messages/
  second, transactions/second, rows/transaction, commit fsyncs, and WAL per
  observation for single-message and adaptive-group modes;
- zero committed MTR traces without identity/outbox state, replay-safe graph
  repair after forced post-source-commit failures, and bounded graph-outbox lag;
- recovery PubAck without a durable `RecoveryResolvedV1` never reclaims local
  proof, and lost/replayed resolution converges without duplicate transitions;
- bulk poison at its DLQ/quarantine capacity cannot consume the interactive
  rejection reserve or block bounded interactive progress;
- stable NATS/database disk use during a 72-hour hourly-scan soak; and
- no row-delete/vacuum storm for retained sweep/MTR history.

Benchmarks cover 1k/10k/100k/1M hosts, zero/five/ten/fifty ports, MTR-heavy
profiles, 1-1,000 concurrent agents, full and timer-fragmented frames at the target and frozen hard sizes
limits, maximum headers/compression, stalled bulk transport, delayed PubAcks, NATS/core outages,
redelivery, rolling upgrades, real CNPG WAL/index behavior, and retention.
Every result records the exact CPU/memory allocation, gateway and EventWriter
replica/worker counts, total physical streams and consumers/RAFT groups,
connections, stream-map version, traffic-class backlog/oldest age, stream leader/
replica placement, per-stream and
aggregate PubAck throughput, NATS fsync storage/network, CNPG topology, Repo pool
size/checkout latency/timeouts, transaction credits, schema/indexes/storage,
site/agent/execution mix, frame size, messages/second, transactions/second, rows/
transaction, commit fsyncs, domain rows/second, lock waits, WAL bytes per
observation, fsync latency, and tail latencies. Per-worker and per-logical-partition rates are
diagnostics, not substitutes for the aggregate gate. If one CNPG primary cannot
pass, rollout stops; adding consumers is not a substitute for a separately
designed stable network-scope/partition-to-database placement strategy.

## MTR Scheduling Guardrails

Every MTR-enabled profile has explicit per-site and global target, trace,
probe-rate, concurrency, duration, and backlog budgets. The compiler estimates
completion time from target count, hop/probe settings, rate, and assigned agent
capacity. It rejects or requires an explicit override when the estimated run
overlaps the next interval.

Large fleets use deterministic sharding, baseline sampling/rotation, critical
device/path selection, anomaly-triggered traces, and incident fan-out. "Run a
deep MTR against every million-host target every hour" is supported only if an
operator-supplied capacity plan and benchmarked storage budget make it viable;
it is never an implicit default.

## Migration and Rollback

1. Capture current JSON/proto size, CPU, allocation, gateway, NATS, CNPG, and
   storage baselines with representative fixtures.
2. Land new protobuf schemas, golden cross-language fixtures, capability fields,
   assignment fencing, additive network-scope columns, DB keys/ledger/retention
   structures, and no behavior change. Run an online idempotent shadow backfill
   for retained sweep/MTR rows from agent/site ownership while legacy writes
   continue. Persist a durable CDC cursor, capture every post-water write, and
   apply that delta continuously while historical backfill runs. Maintain a hard
   delta byte/age budget; slow or stop new legacy scan admission before capture
   can exhaust it. Open the final barrier only after catch-up reaches a configured
   bounded tail. Quarantine ambiguous rows rather than guessing;
   populate partition-local sweep/trace identity keys and legacy migration
   identity times, detect same-scope ID/content collisions, and continuously
   validate every scope-bound read/join without holding the cutover barrier for
   historical volume or creating a permanent per-observation side table.
3. Create the finite route-profile subjects, ACLs, streams, pull consumers, DLQ,
   signed registry snapshots, and exact historical contract bundles before any
   producer-plane assignment is enabled. Enqueue versioned graph-outbox rebuild
   work for retained trace history. At a barrier, stop the legacy direct graph
   writer; one canonical outbox projector maintains migration status. Compare
   relational identity, vertices, edges, and properties; switch reads only after
   network-scope-safe parity, then retire unscoped graph data after the rollback
   window closes.
4. Set and enforce a minimum `edge-records:v1` agent/gateway/producer-adapter
   version. Older agents receive no new producer-plane assignment and are
   upgraded or remain ineligible. This design does not add a patched legacy
   sender, a legacy payload family inside `EdgeRecordV1`, or dual-format
   emission for new work.
5. Establish a destination database-admission epoch. Reserve static worst-case
   capacity for every not-yet-enrolled durable-record writer, then fence/drain it
   before moving that reserve to grant-aware
   source/graph/reconcile/recovery/DLQ workers. Readiness requires every in-scope
   writer generation to enroll and keeps sync/control/background pools separate.
6. Hard-cut one cohort at a short barrier. Stop new legacy admission for that
   cohort, let already-issued bounded work finish or fence/partialize it, drain
   only pre-cutover gateway/core/CDC backlog to a persisted final
   scope/origin/source watermark, and remove every old authoritative writer.
   Historical backfill MUST already be complete; the barrier never scans or
   rewrites unbounded history. Advance the ingress epoch only after no old writer
   can accept data.
7. After that watermark, assign new cohort work only through the common producer
   API and `EdgeRecordV1`. There is no per-execution format choice and no
   authoritative legacy shadow. A non-writing offline/shadow decoder may compare
   fixtures, but it cannot receive production assignments or mutate domain
   tables.
8. Canary each output contract and compare record counts, DB rows, lifecycle and
   snapshot state, OCSF/derived views, trace/hop fidelity, lag, spool pressure,
   memory, latency, network-scope reads, and graph parity. Expand by hard-cut
   cohorts only after the preceding cohort drains and passes its gates.
9. Migrate built-in sweep/MTR, Wasm outputs, native/OTLP relay, and Armis inbound
   inventory in that order; remove each old JSON/lossy/specialized producer path
   and duplicate metric expansion once its pre-cutover backlog is drained.

Rollback is admission-first, not format fallback. Stop new affected assignments
and producer runs, keep the minimum-version agents, gateways, registry bundles,
streams, and consumers running until every `EdgeRecordV1` in agent spools,
JetStream, DLQ, and projection/recovery queues reaches a terminal disposition,
then deploy a forward fix or explicitly cut a new cohort. No rollback emits new
legacy JSON, deploys a binary that cannot read the active spool version, or
falls back to ERTS/direct database writes. A consumer failure pauses consumption
and new admission while durable ownership remains intact.

## Alternatives Rejected

### Keep direct gRPC/ERTS and only replace JSON with protobuf

This reduces bytes but preserves false ACKs, volatile buffering, singleton core
routing, no replay, whole-run materialization, and the 64 MiB RPC window.

### Put the full MTR trace in each sweep host result

This couples heavy traces to latency-sensitive reachability, inflates every
retry, creates cross-table partial-fanout problems, and violates the dedicated
JetStream-first telemetry path. Stable correlation provides coherence without
physical co-location.

### Reuse generic MetricBatch for the full MTR trace

The existing mapping is lossy and expands one trace into hundreds of generic
points. A dedicated trace schema is both smaller and semantically complete.

### Store each whole scan or normal MTR trace as an object

This removes streamability, adds upload/reference/fetch/GC coordination, and
still consumes the current NATS Object Store's JetStream disk. Bounded domain
records are the simpler unit.

### Reassemble the entire scan in core

This recreates memory scaling, head-of-line blocking, and a large failure blast
radius. Every batch must be independently useful and idempotent.

## Resolved Design Values

- Target encoded `EdgeRecordV1`: 256 KiB.
- Hard encoded sizes: `MaxRecordBytes` / `MaxFrameBytes` / `MaxClientMessageBytes`,
  whose values are frozen by the edge record v1 wire ABI change. They are checked
  BEFORE decode and shared by the Go `edgerecord` package and the Elixir `WireDecode`
  boundary.
- Initial logical partitions: 64 per route-profile/partition-hash version.
- Logical partitions map disjointly to one or more benchmark-sized physical
  stream/RAFT groups through an audited map version; subject partitions never
  have overlapping authority. Physical shard count is a required deployment
  sizing result, not a wire-protocol constant.
- Bulk and interactive use disjoint physical streams and persistence durables,
  even in the smallest supported deployment. Within one class/route profile and
  physical stream, one registry-dispatching persistence durable is the initial cardinality;
  any worker may process any logical key and database guards provide correctness.
- Each CNPG destination has one hard capacity budget split explicitly among
  durable-record data plane, sync, control/API/Oban, and background/maintenance work.
  Inside the durable-record pool, one fenced resident/write-byte/row/active-transaction/
  commit-rate budget
  covers source, graph, reconcile, recovery, DLQ, rollup, and repair writers,
  with unborrowable interactive and recovery/reconcile floors whose sum never
  exceeds the durable-record total.
- Initial sweep count guard: 2,000 hosts.
- Initial MTR count guard: 128 traces.
- Hard projected-row guards: 10,000 sweep rows and 5,000 MTR rows per message.
- Agent is the durable pre-JetStream spool owner.
- Durable bulk, durable interactive, and reserved spool-recovery control use
  independent spool/credit sequence lanes; a continuous lane requires its own
  benchmark/admission proof. Traffic class remains immutable through reconcile,
  graph, DLQ, redrive, and quarantine. Producer/package cardinality never creates
  unbounded lanes, connections, streams, or durables.
- Each lane has an independent bidirectional RPC; bulk, interactive, and recovery
  use separately pooled HTTP/2 and NATS publisher connections with independent
  windows and pending-byte ceilings.
- One atomic agent-filesystem allocator covers all spools, quarantine,
  producer-receipt/idempotency and recovery journals,
  rollover amplification, metadata, and scratch while reserving an unborrowable
  recovery/control/terminal floor.
- Gateway durability means a validated JetStream PubAck, not Core NATS publish.
- JetStream stores the exact `EdgeRecordV1` bytes the sink emitted; minimal NATS
  headers carry only publication/stream placement, an opaque delivery ID, a publisher-authenticated
  transport-provenance header (gateway-stamped for edge, service-stamped for service-ingress; record_sha256 + original coordinates + delivery-proof audit), and route-map diagnostics. Semantic routing/schema/provenance/cost authority stays
  in the signed binary record.
- Broker publication IDs are computed over the ABI-frozen transcripts (members and
  order defined there, not enumerated here). What this design relies on is that they
  commit both the exact-record checksum `record_sha256` and the immutable
  semantic-envelope digest, so a slot reused with different bytes is not hidden by broker
  deduplication; delivery coordinates are excluded from the LEDGER digest so
  recovered copies still deduplicate semantically across lanes.
- Persistence uses `AckExplicit` and bounded adaptive compatible-message
  transactions; every constituent delivery is ACKed individually only after the
  containing commit.
- Sweep domain uniqueness uses scheduler-owned identity time, MTR uses UUIDv7-
  derived trace identity time, and ordinary correctness metadata retires by whole
  partition behind a finite replay watermark. Bounded exceptional holds preserve
  unresolved audit/redrive state without permanent side rows per host or trace.
- Well-formed non-conflicting events never depend on broker arrival order; plans,
  attempt state/evidence, and data are independently reconcilable from stable
  sequences and watermarks. Identity collisions are integrity failures with an
  explicit first-committed quarantine/repair rule.
- Stream capacity and retention cover the admitted outage window, catch-up
  interval, redelivery headroom, and safety margin rather than peak ingress
  multiplied by retention alone.
- Sweep shard reassignment uses a monotonic fenced assignment epoch plus a
  scheduler-signed, network-scope/agent/range-bound capability.
- Full MTR trace is a separate authoritative protobuf event.
- Object references are not used for ordinary sweep/MTR observations.

Benchmark results may lower operational limits or increase partition count
before first rollout. Changing the wire meanings, ACK boundary, event split, or
idempotency model requires a new OpenSpec revision.
## Appendix A — moved

The byte-exact cryptographic grammar tables moved to the `freeze-edge-record-v1-abi`
change, which owns them. They are NOT duplicated here: two byte-identical copies of
a frozen grammar is exactly the dual-ownership this boundary reset removes, and a
divergence between them would be invisible until a cross-language fixture failed.

See the frozen edge record v1 wire ABI's Appendix A.

## Ledger replay/conflict outcomes

The per-outcome behaviour the authorization requirement refers to. Wire SHAPES and
the wire-carried enum MEMBERS are frozen by `freeze-edge-record-v1-abi`; the outcome
MEANINGS below, and what a runtime does with them, are owned here.

| Ledger lookup by `(network_scope_id, event_id)` | Stored `semantic_envelope_sha256` | Outcome |
| --- | --- | --- |
| miss | -- | atomic insert under a unique constraint |
| hit | matches (even if `record_sha256`/bytes differ) | replay -- commit at most once |
| hit | differs | `EVENT_ID_CONFLICT` -- DLQ the LATER offending record's exact bytes, recording the first-accepted `semantic_envelope_sha256`/`record_sha256` for forensics; the first-accepted committed row stays immutable and is never moved to the DLQ |
| `edge_slot` `(network_scope_id, authenticated_agent_id, spool_id, sequence)` reused with a different `record_sha256` | -- | transport-integrity violation, independent of the ledger |

### Publish one authoritative record, derive bounded views

Every output contract defines deterministic domain identity, revision/merge
semantics, and authoritative-versus-derived status. A grant forbids a producer
from emitting the same fact simultaneously as typed output, extension output,
`MetricBatch`, OCSF, plugin-result JSON, or a lossy add-on copy. The agent does
not publish a second generic representation of every host, port, MTR hop,
inventory object, or plugin metric. The canonical domain stream is subscribable
by persistence, anomaly/causal, and other real-time consumers.

The persistence projector may write required low-cardinality execution/scanner
metrics in the same transaction. A separate stateless normalizer may publish a
derived `MetricBatch` only if an existing consumer cannot read the domain event;
that publisher must be unique, idempotent, correlated to the source event, and
must not recreate per-host/per-hop duplication.

## Gateway publication and EventWriter pipeline

**Authorization is four separate decisions** (never one boolean; each returns a
typed disposition):

| Decision | Owner | Outcomes |
| --- | --- | --- |
| Historical collection proof | verifier; ONLY the signature/key/trust-chain grant is cacheable by capability digest + trust-policy epoch (body observation/event-time and body-to-claim joins are always evaluated per record) | `valid` / `invalid` / `historically_revoked` / `unavailable` (must validate the authoritative BODY observation/event times against the signed collection interval, not only the UUIDv7 identity time; rotation keeps key history; compromise revokes it) |
| Delivery mode/reason | delivery layer | `fresh` / `renewal` / `rollover` / `late_fenced_delivery` (a stale-fence historical delivery, not a "replay") |
| Gateway publication | gateway | `primary_publication` / `audit_publication` (valid historical, stale fence) / `quarantine_publication` (admitted poison) / `security_quarantine_publication` (a COMPROMISE-revoked key -- a distinct SECURITY variant: the `EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_QUARANTINE` disposition routed to the security-quarantine DLQ, ledger_only, reachable, grant-free) / `retryable_rejection` / `permanent_rejection` (invalid/unauthorized/oversize at a known slot) |
| EventWriter projection | EventWriter | `authoritative_apply` (ledger + domain) / `ledger_only` (ledger idempotency/audit, NO domain projection) / `conflict_quarantine` |

HOW those four decisions are evaluated -- the gateway publication matrix, the
ordered EventWriter pipeline, PubAck and DLQ routing, the transactional fence, and
redrive -- is RUNTIME and lives here. The edge record v1 wire ABI freezes only the
values carried on the wire (`EdgeSourceAuthorizationKind`,
`EdgeRecordDispositionKind`, the `DeliveryMode` constants) plus the
publication/projection separation invariant. The projection outcomes, the
historical-proof resolver verdicts, and the internal publication subtypes above are
owned here.


The runtime evaluation of the four separate authorization decisions. The ABI change
freezes the DIMENSIONS and the values carried on the wire; the historical-proof,
projection, and internal publication vocabularies below are owned here. This is the
matrix the authorization requirement refers to.

The gateway's responsibility ends at PubAck; EventWriter owns everything after.
Two separate matrices therefore fix behaviour, one per component.

The gateway decision matrix fixes, per outcome, the publication, the destination
stream/DLQ, the PubAck requirement, the sender RPC disposition, and whether the
agent may resolve its spool entry. The gateway's "historical proof" column is
ENVELOPE-level ONLY -- the signed capability's validity over the identity-time interval;
the authoritative BODY observation/event-time check belongs to EventWriter (pipeline step
6), so no gateway row requires body fields:

| Historical proof | Delivery mode / fence | Gateway publication | Destination | PubAck | Sender RPC disposition | Agent spool entry |
|---|---|---|---|---|---|---|
| valid | fresh/renewal/rollover, fence current | primary_publication | primary stream | required | `EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE` | resolved (after PubAck) |
| valid | epoch < active fence (late_fenced_delivery, valid delivery grant) | audit_publication | audit stream | required | `EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUDIT_ONLY` | resolved (after PubAck) |
| ENVELOPE-level admitted-but-poison content the gateway CAN detect after bounded decode (wire-hygiene / unknown-field malformation; NOT oversize, NOT envelope-to-grant mismatch, NOT body decode or body-to-claim, which are EventWriter) | any | quarantine_publication | quarantine DLQ | required | `EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_QUARANTINE` | resolved (after PubAck) |
| historically_revoked (COMPROMISE-revoked production/source signing key) -- a REACHABLE TERMINAL security outcome that PRECEDES fence/late-grant classification and needs NO delivery grant | any (grant NOT consumed) | security_quarantine_publication | security-quarantine DLQ | required | `EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_QUARANTINE` (security) | resolved (after PubAck) |
| invalid/unauthorized AT A KNOWN delivery slot: signature/structure invalid, an oversize FRAME/RECORD whose authenticated lane/sequence is known, OR envelope-to-grant mismatch -- none is `quarantine_publication` | any | permanent_rejection | reject-audit DLQ | required | `EDGE_RECORD_DISPOSITION_KIND_REJECTED_PERMANENT` | resolved (after PubAck) |
| unavailable (registry/key not loadable at gateway) or transient publish failure AT A KNOWN slot | any | retryable_rejection | none | none | `EDGE_RECORD_DISPOSITION_KIND_REJECTED_RETRYABLE` (WOULD_BLOCK) | UNRESOLVED |
| PRE-SLOT transport failure (NO delivery slot exists): a gRPC length prefix over `MaxClientMessageBytes` rejected BEFORE buffering, a poisoned/oversize LANE-OPEN handshake, or a poisoned client-message/frame with no recoverable authenticated lane/sequence | none | (transport) LANE CLOSE | none | none | none -- NO per-delivery disposition (lane torn down; agent reconnects) | UNRESOLVED (retransmitted on reconnect) |

Gateway is stateless and CANNOT detect EVENT_ID_CONFLICT (that is EventWriter).
primary_publication does NOT imply authoritative_apply -- EventWriter re-checks the
current fence.

EventWriter (post-PubAck) evaluates an ORDERED decision pipeline (precedence), NOT a
flat table, so fence/audit status cannot mask poison, a compromise, an unbound slot, or a
conflict. The semantic-envelope digest is RECOMPUTED and VERIFIED in step 1 BEFORE it is
ever used as the ledger replay key (step 5); the trusted transport slot is extracted and
bound in step 2 BEFORE any terminal decision; and the trust outcome is evaluated for EVERY
record in step 3 so compromise handling is REACHABLE and cannot be skipped into an
authoritative apply. Evaluate in this order; the FIRST match wins:

1. Transport / envelope validation: received `record_bytes` hash == declared
   `record_sha256`; bounded envelope decode; wire hygiene / unknown-field reject; and
   RECOMPUTE + verify `semantic_envelope_sha256` from the decoded envelope. The digest is
   VERIFIED HERE, before it is ever used as a ledger key. Fail -> `conflict_quarantine`
   (the durable slot is bound first, per step 2 / Blocker 5, so the DLQ'd frame still
   leaves an immutable binding).
2. Trusted slot extraction + binding: extract the `edge_slot`/`service_slot` from the
   authenticated transport provenance; immutably bind `slot -> record_sha256` for EVERY
   accepted delivery (primary, audit, replay, poison, conflict) BEFORE any terminal
   decision and before any source ACK. Slot binding precedes all terminal dispositions, so
   a later frame reusing the slot with a different `record_sha256` is caught as a
   transport-integrity conflict rather than silently accepted.
3. Trust outcome (historical collection proof): evaluate `valid` / `invalid` /
   `historically_revoked` / `unavailable` for EVERY record (the signature/key/trust-chain
   grant is cacheable by capability digest + trust-policy epoch). `invalid` (signature /
   structure / envelope-to-grant unauthorized) -> `permanent_rejection`.
   `historically_revoked` (a record otherwise valid but whose signing key was
   compromise-revoked -- resolved HERE, NOT silently into `authoritative_apply`) ->
   `ledger_only` audit row + PubAck the affected record to the security-quarantine cohort
   DLQ (see the compromised-cohort remediation below), THEN source-ACK the original
   delivery. `unavailable` (key/trust store not loadable) -> NO ACK, pause; the message
   stays pending.
4. Readiness: the pinned contract bundle's registry/projector/schema are LOADABLE AND the
   exact projector generation is DEPLOYED. Not loadable, OR a valid-but-not-yet-deployed
   schema -> NO ACK, pause/not-ready (deployment failure, NOT poison); the message stays
   pending. (This precheck runs BEFORE payload decode so an undeployed schema never
   becomes poison.)
5. Ledger conflict / replay: `(network_scope_id, event_id)` lookup. The ALREADY-VERIFIED
   (step 1) `semantic_envelope_sha256` MATCHES a committed row -> REPLAY: idempotent
   success, source ACK, no re-projection. DIFFERS -> `EVENT_ID_CONFLICT` ->
   `conflict_quarantine` (DLQ the LATER offending bytes + first-accepted digests;
   first-accepted row immutable). Absolute event-id conflict is checked BEFORE body poison.
6. Payload decode + body-to-claim + body-time: decode the domain payload; body-to-claim
   join (scope/agent/run/range/traffic-class/count vs the signed envelope); the body
   observation/event-time falls within the signed collection interval. Fail ->
   `conflict_quarantine` (DLQ).
7. Transactional fence + domain commit: `SELECT ... FOR UPDATE` / conditional `UPDATE` of
   the fence/assignment row in the SAME transaction as the domain effects + ledger row.
   Current fence -> `authoritative_apply`; stale/advanced fence -> atomic `ledger_only`.
   Database unavailable at any commit point -> NO ACK, NO TERM/poison; pause new pulls;
   the reservation lapses at the bounded processing deadline via AckWait expiry
   (redelivery, NOT counted toward a finite MaxDeliver); agent ownership NOT restored.

Precedence note: transport / slot / trust / conflict / poison (steps 1-6) precede the
fence downgrade (step 7), and slot binding (step 2) precedes every terminal decision, so
no downgrade or audit path can mask a conflict, a compromise, or an unbound slot -- an
audit publication that is ALSO an event-id conflict is handled as a conflict, and a
compromise-revoked record resolves to `ledger_only` + security-quarantine, never to a
stale `authoritative_apply`. Semantic-digest VERIFICATION (step 1) precedes its use as the
ledger replay key (step 5).

Failure-disposition deconfliction:

- MISSING / duplicate / unknown-version transport-provenance -> a DISTINCT
  `provenance_missing` quarantine whose DLQ record uses ONLY what is available (the
  publish subject, the raw `record_bytes`, and any `Nats-Msg-Id`-derivable coordinates)
  and does NOT require the missing provenance envelope. It is separate from
  `conflict_quarantine`, which presumes a decodable provenance/envelope.
- OVERSIZE (raw frame/record exceeds the hard byte bound, rejected before decode -- and,
  on the streaming gRPC ingest path, at the TRANSPORT before the body is buffered or
  decompressed) and GRANT / envelope-to-grant MISMATCH resolve to `permanent_rejection`,
  NEVER `quarantine_publication`, WHEN a delivery slot exists; a PRE-SLOT oversize (a
  length prefix rejected before buffering, or a poisoned/oversize lane-open) has no slot,
  so it is a transport-level lane close with NO per-delivery disposition (see the gateway
  matrix). Quarantine is for admitted-but-poison content; permanent rejection is for
  structurally invalid / unauthorized / oversize input at a known slot.
- POST-PubAck compromise revocation resolves in the trust-outcome step (step 3) as
  `historically_revoked`: EventWriter writes a `ledger_only` audit row and PubAcks the
  affected record to the security-quarantine cohort DLQ, THEN source-ACKs the original
  delivery: the record is durably captured, never authoritatively projected, and never
  left unresolved. On compromise revocation of a signing key, EVERY record signed by that
  key is `historically_revoked` -> `ledger_only` + security-quarantine cohort, and any
  already-authoritatively-projected domain rows from that key/cohort are marked
  `security_held` and scheduled for operator-authorized retraction/redrive under a fixed
  safe bundle; redrive uses a durable synthetic spool + fresh delivery/map envelope + a
  capability bound to the immutable catalog record, and the ingest ledger makes
  already-committed events harmless.

EventWriter's fence check (step 7) SHALL be transactionally atomic with the
domain commit: either `SELECT ... FOR UPDATE` on the projection-fence/assignment
row, or a conditional `UPDATE ... WHERE active_epoch = <read epoch>`, INSIDE the
SAME SQL transaction as the domain effects and the ledger row; fence ACTIVATION uses
the SAME serialization point (it bumps the same row). If the fence advanced between
read and commit, the transaction observes it and the record atomically becomes
`ledger_only` (no authoritative domain rows), never a stale `authoritative_apply`.

Retryable outcomes NEVER advance the contiguous resolved prefix; the record stays
eligible for idempotent redelivery. A stale producer epoch presented under a valid
delivery grant is `audit_publication` + `late_fenced_delivery` + `ledger_only`
(durable forensic record, no authoritative projection), never a permanent rejection
and never an authoritative apply.
