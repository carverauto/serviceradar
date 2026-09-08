# Design: Harden the flow attribution pipeline

## Context

The current path crosses Rust eBPF collection, a Go agent-owned pending prefix,
Elixir gateway forwarding, core persistence, and a later CNPG correlation pass.
The three issues occur at different boundaries:

| Boundary | Established evidence | Current consequence |
| --- | --- | --- |
| Kernel to netprobe (#4029) | UDP rows arrived after netprobe 0.2.52, but three completed TCP handshakes produced zero TCP rows | TCP failure is silent and is not yet localized between eBPF emission and userspace tuple/owner resolution |
| Core admission (#4031) | A named singleton executes the flow multi-CTE UPSERT and retries inline | One slow batch blocks unrelated status handling; retained plugin results have a similar synchronous path |
| Gateway acknowledgement (#4030) | A failed strict forward can be buffered and converted to `:ok`; unary and streaming responses hardcode `received: true` | The agent deletes a pending prefix that no durable component accepted |
| Correlation topology (#4029) | The observed sampled-flow set contained no rows involving the sole netprobe host | Correct producer records still cannot stamp an OCSF flow without endpoint and time overlap |

The exact TCP producer defect remains deliberately unclaimed. Fixed kernel
offsets without CO-RE are a portability risk, but attach success alone does not
prove that this was the failure on the measured host. The implementation must
first produce evidence that distinguishes missing kernel events from userspace
tuple or ownership misses.

Current OpenSpec text also spans multiple generations of the architecture. The
deployed route is agent-up `FlowAttributionEventBatch` delivery, durable
current-state persistence, and core-side CNPG correlation. Static host-slice
replay and moving attribution to the generic add-on/OTLP relay are not part of
this design.

## Goals / Non-Goals

### Goals

- Prove that a real TCP connection on a supported kernel produces an
  owner-resolved attribution record, or report an explicit unavailable/failure
  state that identifies the failed boundary.
- Preserve correct exact-first UDP and protocol-specific correlation while
  exposing whether source topology permits any match.
- Keep expensive flow and retained plugin-result work out of shared singleton
  mailboxes without acknowledging before durable completion.
- Return a normal negative acknowledgement for retryable/uncommitted
  agent-retained delivery failures and reserve gRPC errors for invalid requests.
- Bound memory, concurrency, and wait time at every new admission boundary.
- Make verification depend on post-rollout database artifacts, not only job
  success logs or gateway responses.

### Non-Goals

- Redesigning the flow collector, event writer, or network exporter topology.
- Adding a second attribution detector or changing attribution event schema.
- Making best-effort gateway buffering durable.
- Increasing database concurrency to maximize throughput at the expense of
  deadlocks, WAL, or unrelated core work.
- Introducing partial acknowledgement semantics into the protobuf API.

## Decisions

### 1. One contract, three sequenced implementation lanes

The change defines the full ownership chain in one proposal because local fixes
can otherwise recreate loss at the next boundary. Implementation remains split:

1. #4029 fixes and verifies TCP production plus correlation diagnostics.
2. #4031 introduces bounded, commit-confirmed core admission.
3. #4030 carries the resulting delivery outcome through gateway responses and
   preserves ownership at the agent.

#4029 can land independently. #4031 lands before #4030 so a negative response
has a well-defined set of core queue-full, timeout, task-exit, and persistence
failure outcomes.

The OpenSpec change remains open until all three lanes land and verify; it is
not archived after an individual implementation pull request. Each pull request
links this change and updates only its own checklist section. This deliberately
trades an indivisible archive unit for one end-to-end ownership contract.

### 2. TCP correctness is verified against the loaded program

A Bazel integration target will load the same netprobe eBPF objects used in
production, open a real loopback TCP connection, and assert that the
`inet_sock_set_state` path produces a TCP attribution record with the expected
local/remote tuple and process identity. Unit tests that construct an event do
not satisfy this gate.

The verifier and runtime counters divide the path into observable stages:

- program attach/readiness;
- TCP state event observed in the ring;
- tuple extraction accepted or rejected;
- owner cache hit or miss;
- userspace record inserted or updated;
- batch handed to the agent.

The implementation fixes the first stage whose evidence fails. If the active
kernel layout cannot be read safely, netprobe reports attribution unavailable
for that protocol/build combination rather than remaining healthy with a
permanent zero-record stream. This proposal does not preselect CO-RE, a new
tracepoint, or adjusted fixed offsets before the loaded-program test identifies
the failing boundary.

Any netprobe source change follows the native add-on contract: bump
`addons/netprobe/addon.yaml` and `NETPROBE_VERSION`, build the bundle, and run
the version-bump and native-add-on build gates.

### 3. Correlation becomes deterministically exact-first and topology-aware

The deployed candidate families are preserved rather than narrowed as part of a
producer fix. Bidirectional exact TCP/UDP 5-tuples rank first. A lower-ranked
wildcard-listener candidate may match a TCP or UDP attribution whose remote
address and port were intentionally collapsed to the listener wildcard while
the local endpoint, protocol, partition, and time window match. The relaxed UDP
service-port candidate preserves endpoint roles and the remote service port but
allows the local ephemeral port to differ; this covers both netprobe's
intentional zero-port coalescing and exporters that report a different non-zero
ephemeral port. ICMP/ICMPv6 remain port-independent.

The existing topology transforms also remain lower-ranked than local exact and
service candidates. Node-SNAT maps the attribution agent to its registered node
IP while preserving the remote endpoint and protocol-specific service port.
Public-endpoint matching maps a known VIP/protocol/port to the attributed
backend socket. The current SQL assigns public candidates their raw
`exposure_rank` (including zero), which can tie the exact-local rank. This
change offsets public-endpoint ranks below the local exact, wildcard/relaxed,
and node-SNAT ranks while preserving the relative Gateway, LoadBalancer/
ExternalIP, and other exposure ordering. No fallback may displace an eligible
exact candidate.

Each correlation pass exposes bounded-cardinality counts for flows considered,
attributions considered by protocol, exact, wildcard-listener, relaxed UDP,
node-SNAT, and public-endpoint candidates, ambiguous candidates, stamped rows,
and no-overlap outcomes. Sampled diagnostic logs may include agent/partition
identifiers; exported metric labels do not add unbounded process, address, or
agent cardinality.

`no_topology_overlap` is a first-class outcome. It means the sampled-flow set
contains no eligible endpoint/time overlap with current attribution rows; it is
not reported as a correlator implementation success or failure.

### 4. Core uses two independently bounded admission lanes

Flow attribution and retained plugin results use separate supervised lane
instances so saturation in one cannot consume the other's budget. `StatusHandler`
and `ResultsRouter` classify the agent-retained work, hand the original `GenServer.from()`
to the appropriate lane, and return `{:noreply, state}` immediately. A lane
replies only after its worker reports the durable result.

Initial defaults are deliberately conservative:

| Lane | Concurrency | Total admitted items | Total retained payload bytes | Per-agent admitted items | Maximum queue wait | Worker timeout |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Flow attribution | 1 | 16 | 64 MiB | 4 | 2 s | 20 s |
| Retained plugin result | 2 | 32 | 64 MiB | 8 | 2 s | 20 s |

Item, byte, per-agent, and time bounds are runtime-configurable, but both item
and byte caps are mandatory. Concurrency is fixed at one flow worker and two
retained-plugin workers for this change; changing either value requires a
follow-up review of database contention, bounded gateway forwarding, and sender
deadline math. The total count, byte, and per-agent caps include queued and
in-flight work. Byte admission uses the retained encoded payload size plus fixed
envelope overhead. A job that exceeds its queue-wait budget is rejected before
starting. The existing flow-attribution gateway call deadline is 25 seconds and
the retained-plugin call uses the existing 30-second default. For either lane,
`queue_wait + worker_timeout + 3s <= gateway_core_call_timeout`; the flow call
must not exceed 25 seconds while the agent flow RPC remains 30 seconds, and the
retained-plugin call must not exceed 30 seconds while the sender uses 30-second
wave slots. Queue wait may be lowered but not raised above two seconds and
worker timeout may be lowered but not raised above 20 seconds.

The flow lane remains single-concurrency because parallel UPSERTs to
the same churn-heavy table would trade mailbox blocking for database deadlocks.
Plugin concurrency is fixed at two until representative handler and database
measurements plus a revised deadline contract justify a change. Per-agent caps prevent one edge agent from
occupying every pending slot.

Merge order is not activation order for retained plugins. The #4031 core change
ships its retained-plugin routing behind a compatibility gate that preserves the
legacy path by default. The flow lane may be enabled immediately, but retained
plugin routing is enabled only after the #4030 gateway with bounded two-way
forwarding is deployed. This prevents an old sequential gateway from spending
up to ten 20-second worker windows inside the agent's 110-second stream deadline.

Queue-full, queue-wait timeout, worker timeout, task exit, and persistence error
all reply with an explicit error that the gateway maps to `received: false`.
The lane records depth, retained bytes, queue wait, run duration, admission
rejection, timeout, task exit, and completion outcome. An agent-retained cast,
which has no caller to acknowledge, may use the same bounded lane for legacy
best-effort compatibility but must never execute database work inline; no
production agent-retained producer may use that cast path.

### 5. Persistence stays one logical acknowledgement unit initially

The existing flow producer targets at most 4,096 events and 6 MiB per batch,
well below the 16 MiB stream-chunk limit. This change measures queue wait,
worker runtime, database locks/deadlocks, WAL, and retry rate before changing
that unit.

Splitting one agent-owned prefix into multiple database commits changes atomic
acknowledgement, retry, and duplicate semantics. It is therefore deferred unless
measured execution still exceeds the 20-second worker budget after admission
isolation. A later chunking change must define sub-batch idempotency and partial
commit recovery explicitly.

### 6. `received` reports durable ownership for the whole RPC

Flow attribution and capability-qualified retained plugin results are the exact
agent-retained delivery source set governed by this change. An agent-retained
`PushStatus` request contains exactly one service. Each non-empty chunk in an
agent-retained `StreamStatus` RPC contains exactly one service, every chunk uses the same source, and the stream contains no
best-effort status. This preserves the current multi-chunk retained-plugin
producer while making the RPC-wide acknowledgement domain explicit. A source
change or mixed chunk returns `invalid_argument`.

The existing `otlp-relay` source is not part of this set. It keeps its hard gRPC
error contract because the edge add-on, rather than the Go agent status queue,
owns its durable retry spool.

The gateway accumulates an agent-retained stream within the existing 16 MiB
per-chunk and 64 MiB per-stream caps and validates the complete stream before
forwarding any service. A flow-attribution stream contains exactly one non-empty
chunk and is processed at concurrency one, keeping its worst-case core work
inside the 30-second agent deadline. A retained-plugin stream may contain up to
ten chunks and is processed at concurrency two. The Go agent deadline becomes
`max(30s, ceil(chunk_count / 2) * 30s + 15s)`: five worst-case waves therefore
receive 165 seconds. Each wave receives eight seconds of headroom beyond the
two-second queue plus 20-second worker budget, followed by 15 seconds of
stream/RPC grace. The gateway starts only the next bounded pair when capacity
is available, so it does not enqueue a ten-item burst behind a two-second core
queue-wait deadline.

For a valid agent-retained request:

- `received: true` means every logical item reached its defined durable
  terminus. For flow attribution this is successful current-state persistence.
  For retained plugin results, both the raw result and a terminal handler
  outcome must be durable. A successful handler produces a terminal success;
  a handler domain failure satisfies the boundary only after that failure is
  durably recorded. A raw row alone is insufficient if terminal-outcome
  persistence fails.
- `received: false` means at least one item did not reach that terminus. The RPC
  itself completes successfully, directives are empty, the shared gRPC
  connection remains usable, and the agent retains the entire ordered prefix.
- A retried request may include an item that committed before a later item
  failed. Both persistence paths must therefore remain idempotent.
- Malformed protobuf content, invalid fields, oversize payloads, identity
  violations, and mixed-source protocol violations remain hard gRPC errors.

Here, oversize means a wire or source-contract violation: more than 16 MiB in a
chunk, more than 64 MiB in a stream, or more than the source's declared maximum
such as the 6 MiB flow batch limit. A valid payload that fits those limits but
cannot enter a deployment's lower configured lane capacity is an operational
admission failure and returns `received: false`; it is not poison.

Both `PushStatus` and `StreamStatus` carry this outcome instead of hardcoding
success. A normal negative response must not call the Go client's disconnect
path.

Hard `INVALID_ARGUMENT` errors and `RESOURCE_EXHAUSTED/payload_too_large` errors
are terminal for the identical bytes rather than delivery retries. The Go
client's equivalent pre-RPC `ErrStreamStatusChunkTooLarge` and
`ErrStreamStatusBudgetExceeded` validation outcomes are terminal under the same
rule; otherwise bytes rejected locally would replay forever without reaching a
gateway. The updated sender removes the complete offending RPC set from
automatic replay as a terminal poison drop, records bounded item and byte
counts plus a bounded reason, and allows later valid work to advance. A local
validation drop does not mark the connection disconnected; a terminal gRPC
response may reconnect before later work proceeds. The sender does not create
a second payload copy or a durable quarantine store. This disposition is not a
positive acknowledgement or downstream commit; transient gRPC errors and
normal `received: false` responses preserve the pending set.

### 7. Agent-retained data never transfers to `StatusBuffer`

Flow attribution and retained plugin results are removed from the volatile
gateway buffer once negative acknowledgement is available. Best-effort sources
retain the existing bounded buffer behavior.

On overflow, telemetry is emitted from the entry actually evicted and includes
bounded `source` and `service_type` dimensions in addition to the existing
reason/gateway/partition context. The buffer also exposes current retained bytes
and dropped item/byte totals by bounded reason. Service names and payload-derived
values are not metric labels.

Gateway shutdown or restart loss for best-effort buffered entries is explicitly
accepted and documented. The system does not promise an exact per-entry loss
count because shutdown callbacks do not run for every failure mode. Operators
rely on the existing drop alert for observed overflow, buffer depth and process
restart signals for possible-loss intervals, and source freshness/republishing
for recovery. Agent-retained sources are excluded precisely because they cannot accept
this loss model.

### 8. Active specifications are reconciled to deployed architecture

The proposal branch updates active change text so it no longer mandates:

- strict UDP client-port equality when netprobe intentionally coalesces the
  ephemeral port;
- a production NetFlow host-slice down-to-agent replay loop;
- migration of flow attribution to the generic relay.

It also narrows `scale-netflow-ingest-isolation` to configured concrete
`flows.raw.<name>` subjects, including NetFlow and sFlow, and corrects the
non-normative workload-identity discovery note. The
`restore-anomaly-alerting-and-surfacing` text is reconciled so its dead
`ATTRIBUTED_FLOW` consumer is removed or remains absent rather than provisioning
a producer for the retired namespace. The retired host-slice and
`flow.attributed.*` subjects are not reserved for a future attribution join.

Historical archived changes are not rewritten. The new `flow-attribution`
capability becomes the focused acceptance contract for the current path.

## Risks / Trade-offs

- **The first loaded-program test may fail on development hosts without BPF
  privileges.** Keep it as a tagged Linux integration target and run it on the
  privileged native-add-on verification worker; unit tests remain useful but
  cannot replace it.
- **Freeing singleton mailboxes can move pressure into PostgreSQL.** Conservative
  lane concurrency, byte caps, execution telemetry, and deadlock/WAL
  measurements prevent uncontrolled fan-out.
- **Negative acknowledgements can increase agent backlog during an outage.** The
  agent already owns bounded queues and preserves the exact prefix on false;
  expose retry/backlog/drop counters and verify recovery after fault injection.
- **A commit can race a caller timeout.** Worker cancellation must cancel or
  roll back in-flight transactions where possible, late replies are ignored,
  and idempotent UPSERT/result keys make a subsequent retry safe.
- **Relaxed UDP matching can be ambiguous.** Exact candidates always win;
  ambiguous relaxed matches are counted and must not be silently presented as
  exact evidence.
- **Topology may make attribution impossible despite a healthy producer.** The
  explicit no-overlap outcome prevents this from being misdiagnosed as a TCP or
  persistence regression.

## Migration Plan

1. Land the proposal and active-spec reconciliation.
2. Land #4029 independently with the loaded-kernel TCP gate, protocol metrics,
   and correlator overlap diagnostics.
3. Land #4031 with both core lanes and failure injection tests while preserving
   current gateway behavior; enable the flow lane but leave retained-plugin lane
   routing behind its compatibility gate.
4. Roll the updated Go agent, including the retained-plugin deadline formula and
   terminal poison-drop handling, to the controlled cohort. The new behavior is
   backward-compatible with the old gateway.
5. Land #4030 so unary and streaming handlers return normal negative
   acknowledgements, retained-plugin forwarding is bounded at concurrency two,
   and agent-retained sources stop entering `StatusBuffer`.
6. Enable retained-plugin lane routing only after the #4030 gateway is ready.
7. Roll out in that order. Confirm each verification run starts after rollout
   completion and query the exact post-rollout database rows for the stimulated
   connection.

Rollback follows the same dependency in reverse and requires no schema
downgrade. While a #4030 gateway is live, its #4031 core outcome contract and
admission lanes MUST remain available. Disable retained-plugin lane routing,
then roll back or disable #4030 gateway behavior before rolling back #4031;
never leave the new gateway pointed at a core that cannot return the typed
durable outcome it requires. Returning to the old gateway behavior temporarily
reintroduces the known false-ack risk and is therefore an emergency
compatibility step, not a safe steady state. The updated Go agent is
backward-compatible and remains deployed during a gateway/core rollback. The
#4029 change is independent and can be rolled back by selecting the preceding
signed netprobe version. A rollback does not alter or delete already committed
attribution rows.
