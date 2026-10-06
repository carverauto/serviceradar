## Context and staging verification

This revision was checked against staging a69ce6dc519d087e5330ef8096c7bc670f1cd2ce.
The earlier proposal is #5266. None of its implementation tasks is complete.

StatusHandler's retained_plugin_result_status?/1 now checks plugin-result source,
the plugin-result-retained:v1 capability, and retained_plugin_admission_enabled.
The last setting now defaults to true (PR #5322 — task 3a.2); the kill switch
RETAINED_PLUGIN_ADMISSION_ENABLED=false restores the previous path. Other statuses must not
be misclassified as retained results, including strings/atoms at supported
normalization boundaries.

ResultsRouter still ingests in handle_call and flushes serially in
handle_info(:flush_results). StatusHandler's workload-identity and agent-status
branches still invoke persistence helpers inline. SyncIngestorQueue still uses
an enqueue cast, decodes in handle_cast, and accumulates while work is in flight.
Agent B's merged #5308 bounds gateway core forwarding at 20 seconds inside the
agent's 30-second RPC deadline. This implementation uses a 15-second core budget,
including queueing, execution, and cancellation/reply reserve.

## Goals and boundaries

No Repo/Ash/database call, including a transitive helper call, executes in any
StatusHandler or ResultsRouter handle_* callback. Bounded tasks perform ingestion
and writes; dispatchers classify and reserve work only. Cross-type capacity is
independent, and the retained agent protocol is unchanged. This change does not
introduce distributed ingestion across nodes, new agent wire fields, multitenancy,
or a metrics path that bypasses JetStream.

## Decisions

### 1. Preserve truthful acknowledgements and coordinate one deadline

There are two existing delivery classes:

| Class | Positive response condition | Overload/failure |
| --- | --- | --- |
| Retained plugin, flow attribution, endpoint inventory | Existing durable completion condition has been confirmed by its worker/lane | Not-accepted / received:false; pending payload remains with the agent |
| Existing cast/best-effort status | Existing gateway forwarding acceptance contract | Explicit core rejection/drop telemetry; do not invent a retained guarantee |

For retained plugin results, a committed handler-domain failure marker remains
an accepted terminal outcome, as ResultsRouter.process_retained_plugin already
implements. A persistence failure is not an accepted terminal outcome. The
service-state side effect follows its existing completion contract; merely
starting a task or reserving RAM never satisfies an ack-required result.

StatusHandler admits with the caller reply reference and returns without waiting
for ingestion. The owning worker/lane replies after completion. ResultsRouter's
call path uses the same split-phase handoff rather than blocking on another
GenServer.call. Reply references, reservations, task monitors, and deadline leases
are owned and released exactly once on completion, cancellation, or worker exit.
An expired waiter cannot turn a later completion into a false positive response;
a possible late commit is handled by the existing idempotent agent replay.

The user approved implementation after reviewing #5309, with core strictly below
Agent B's 20-second forwarding budget. Core reserves 15 seconds: at most 2 seconds
for admission/queueing, 10 seconds for execution, and 3 seconds for cancellation
and reply. Invalid timeout combinations fail configuration validation. Carry a
remaining duration across nodes, then use a local monotonic deadline throughout
core; node-local monotonic timestamps must not be compared across machines.
On overload, timeout, unavailable core, worker exit, or unsuccessful persistence,
Agent B returns not-accepted for ack-required statuses. A generic received:true
fallback is prohibited. No wire-level acknowledgement change is proposed, and
repeated retained payloads keep their current deduplication identity.

Gateway #5308 is merged. A metadata-only reservation handshake precedes the full
payload handoff in the gateway/core pairing introduced by this implementation.
Older gateways may use the bounded compatibility dispatcher, but do not provide
the new pre-mailbox byte bound; retained default enablement requires the new pair.

- **Decision: telemetry follows the admission-lane convention.** Every queue
  emits `[:serviceradar, :result_ingestion, ...]` events mirroring
  `[:serviceradar, :admission_lane, ...]` (pending/in-flight count and bytes,
  admission wait, execution duration, completion result, rejection reason,
  timeout, crash), with bounded-cardinality `class` tags, exported by the
  existing `Telemetry.Metrics` reporter.

- **Decision (user, resolved open question): lane metrics are also published on
  JetStream.** In addition to `:telemetry`, a periodic aggregator publishes one
  `serviceradar.metric.v1` MetricBatch per interval on `metrics.ingestion_lanes`
  through `ServiceRadar.NATS.JetStreamPublish`, exactly as
  `ServiceRadar.FlowAttribution.PassMetrics` publishes `metrics.flow_attribution`.
  The batch carries per lane or class: queue depth and bytes, admitted, rejected
  (by reason), NACKed, timed-out counts for the interval, and incomplete sync
  runs. EventWriter's existing METRICS stream and `Metrics` processor persist it
  to whichever telemetry backend is active, so no new consumer and no direct
  database write. The subject does not collide with `metrics.ingest` or
  `metrics.batch`. Publication is per interval, never per message, so it does not
  add load to the path it measures; a failed publish is logged and never affects
  ingestion. The metrics become queryable through `timeseries_metrics`.

- **Decision (user): lane metrics are visible on three surfaces**, delivered as
  the last PR of this change once the lanes exist: (1) Grafana, by registering the
  lane `:telemetry` events as `Telemetry.Metrics` in core-elx's Prometheus
  scrape and adding panels to the chart's ingestion dashboards; (2) a seeded
  ServiceRadar dashboard charting the JetStream-persisted lane metrics from
  `timeseries_metrics` via SRQL; (3) an "Ingestion" card on Settings -> Cluster
  Status showing current per-lane depth and capacity and recent rejects/NACKs
  from a cheap lane-stats call (no database query), linking to the dashboard.
  No alert consumes these metrics in this change.

### 2. Use independent bounded keyed workers

Generalize the existing admission/endpoint-inventory worker patterns instead of
adding unbounded Task.start calls. Each result class has its own queue and
Task.Supervisor, with total/per-key item and byte reservations covering queued,
admitted-but-not-yet-dispatched, and in-flight work. Enforce the admission credit
before placing a large payload in an intermediary mailbox. A short GenServer.call
or Task.Supervisor.max_children alone is not a mailbox/byte bound.

Start with the earlier proposal's small configurable worker defaults: sweep 4;
mapper interfaces/topology 2; bumblebee 2; legacy plugin 2. Mapper interface and
topology work share the same per-agent ordering domain. Sweep keys are agent plus
sweep group; other ordering keys retain the ingestor's existing ownership scope.
Audit all writers, including raw Ecto, before finalizing keys: two agents writing
the same device may need a shared device fence and consistent lock order.
Only one task for a given ordering key is in flight; different keys run fairly
within the class's configured concurrency. A completed command or arrival-order
assumption from #5196 is not imported into these unrelated queues.

Keep retained plugin, flow, and endpoint inventory lanes independently reserved.
Validate aggregate worker/byte budgets against the coordinator's available Repo
pool and memory budget, reserving capacity for acknowledged work and other core
services. Cancellation kills and observes the task before releasing its credit.
Reject a full or unavailable queue explicitly; never fall back to inline writes.
Do not turn task failures into a successful reply. Worker restart behavior and
volatile best-effort queue loss are logged and measured; retained agents replay
unaccepted work as they do today.

Workload identity snapshots and add-on status reports use bounded per-agent
workers, preserving their authentication/ownership checks in the worker. Coalesce
only complete replaceable snapshots, after proving replacement safe; do not
coalesce deltas, commands, or irreversible add-on lifecycle transitions. An
in-flight snapshot finishes before the next snapshot for that key starts.
Service-state updates and endpoint inventory decode/upserts run in workers too.

### 3. Retained lane default and safe rollback

Default retained_plugin_admission_enabled to true and keep source/capability
classification explicit. If the flag is disabled, route through a bounded,
commit-confirming compatibility worker. The flag must not restore database work
inside either singleton. An unavailable compatibility worker rejects safely.
Per-type rollback similarly selects a bounded previous worker implementation or
rejects work; redeploying the prior release is the separate operational rollback.
Do not mix old and new writers for one ordering key during handoff. Drain or
cancel the old owner, transfer ownership once, and rely on retained replay for
unaccepted work. Enabling the default follows Agent B's deadline deployment and
an explicit compatible-version check.

### 4. One flush timer and bounded service-state batching

Keep the existing 250 ms / 200-item batching behavior as configurable defaults.
Represent the armed timer with a timer reference and a generation token, and send
{flush_results, token}. Only a matching token consumes the timer; a cancelled tick
already in the mailbox is ignored. Threshold flush invalidates the previous token
before arming a replacement. No timer runs while there is no pending work.

The service-state batch is admitted to a bounded worker, not written in the
router. If the worker is full, keep only the bounded coalesced pending state and
retry with one tokened timer; do not create another task or timer chain. The
in-flight batch counts against the byte/item bound. Preserve ordering so an
older batch cannot overwrite a newer update; emit completion PubSub only after
its applicable persistence succeeds.

### 5. Bounded sync admission and incomplete-run protection

SyncIngestorQueue.enqueue becomes a short bounded admission operation returning
:ok or a specific rejection such as sync_ingest_queue_full. Retain raw payloads
under item/byte/per-source-or-run bounds that include in-flight work. JSON decoding
and ingestion happen in supervised workers, not in queue/dispatcher callbacks.
Callers must inspect and propagate rejection; converting a rejected enqueue into
success is prohibited. Audit every enqueue and direct-ingest caller before
changing the API.

Preserve run/chunk ordering and the current distinct-population activation guard.
A rejected chunk must not lead to a successful partial snapshot activation or
retirement of devices whose rows were lost. When run identity is available,
record incompleteness through an existing authorized status writer outside the
queue callback. If identity cannot be derived safely before rejecting a raw
payload, do not invent an identity or claim a complete run; activation must fail
closed and the implementation must prove how that rejection reaches the run's
completion guard. This is part of acceptance, not permission to log-and-ignore
an untracked rejection. Source/run metadata extraction must also be bounded and
must not reintroduce JSON decode into the singleton. Restart/replay and an
interleaved rejected run followed by a complete run need regression coverage.

### 6. JetStream queue and latency telemetry is required

Each queue and existing acknowledged lane reports pending/in-flight items and
bytes, admission latency, execution duration, completions, rejections by reason,
timeouts, crashes, and cancellation. Emit canonical protobuf metric envelopes
through a bounded supervised metrics publisher on metrics.ingestion_lanes,
confirm PubAck, and persist only through EventWriter in the configured telemetry
backend. Audit NATS stream/permission coverage before rollout. Local :telemetry
and Prometheus are supplementary, not the durable platform metric path.

Use only bounded class/lane/outcome/reason labels, never agent/device/run IDs.
Sample queue gauges and aggregate latency/counter samples at a configurable
bounded cadence; define gauge versus delta-sum semantics and replay identity.
The publisher has a bounded outage buffer and explicit dropped-sample accounting;
metrics publication cannot block an ingestion ack or recursively publish its own
failure through the failing path. No direct CNPG/StarRocks metric writes, no UASB,
and no retired central anomaly pipeline are introduced.

## Alternatives and trade-offs

A global Task.Supervisor alone lacks per-key order, per-type reservations, and
byte admission. Durable acknowledgement on enqueue would change the retained
contract and needs a separate durable-spool design, so it is rejected here.
More concurrent ingestion exposes row-lock contention: reserve database capacity,
audit shared writers, and measure retries rather than claiming linear scaling
regardless of bottleneck. Reject-newest best-effort work makes overload loss
visible; it does not upgrade the legacy gateway/agent delivery guarantee.

- Should the cast-path classes eventually become acknowledged (gateway call) so
  overflow can be retried by the agent instead of counted as loss? That is a
  gateway and agent contract change and is not proposed here.
- Resolved: queue metrics are also published to JetStream (see Decisions). An
  alert or SLO on them is not part of this change and may be added later.

## Verification and load evidence

Load test-audit before authoring tests. Add behavior tests at owner boundaries:
slow ingestor barriers, cross-type ack completion, retained exact-pending-set
replay, queue fullness including in-flight bytes, timeout/cancellation/worker
crash, service-state completion ordering, stale timer injection, and incomplete
sync-run activation prevention. Trace Repo query ownership to workers for every
supported status class, plus review the transitive Ash call paths; a source-text
search alone is not the proof. No expected-test-count pins.

A targeted synthetic RBE/lab harness compares current staging and the approved
implementation under identical invented fleet inputs and pool/queue settings.
Vary worker concurrency and sustained/burst load, isolate one deliberately slow
type, and include overload and worker failure. Record offered/admitted/completed/
rejected work, queue bytes/high-water marks, throughput, timeout/replay outcomes,
and acknowledgement p50/p95/p99/max. Proposed gate: ack p99 below 15 seconds and
all responses before the 30-second agent deadline, with explicit rejection rather
than silent acceptance when overloaded. Every admitted retained item must reconcile
to its durable terminal record, or remain unaccepted and safely replayable. Report
bottleneck-limited scaling honestly; report retained payloads/drops separately
from best-effort loss. Publish synthetic artifacts and exact commit/config identity.
PR BazelCI must be fully green before the implementation merges. No local builds.

## Rollout and approval

1. User reviews and approves this revised docs proposal. Agent B confirms the
   acknowledgement contract and gateway deadline mapping before paired rollout.
2. Implement bounded queues and metric publisher without enabling new routes;
   validate their bounds, worker failure behavior, and synthetic load harness.
3. Move each class and inline writer onto bounded workers, including compatibility
   paths, with no overlapping owner. Apply the timer and sync admission fixes.
4. Roll Agent B's gateway deadline change, verify supported pairing, and enable
   retained admission by default. Canary with synthetic load and JetStream metrics.
5. Close #5195 and #5210 only after implementation/evidence requirements pass.

The warehouse fault-injection exception from #5302 is separate; this proposal
neither claims those five live scenarios passed nor silently adds a lab rollout.
