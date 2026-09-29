# Design: Distributed sweep result ingestion

## Context

Result delivery today:

```
agent -> gateway -> StatusHandler (coordinator) -> ResultsRouter (coordinator)
                                                   `-> SweepResultsIngestor (inline)
```

`StatusHandler` and `ResultsRouter` are coordinator-only children, started on
the elected coordinator node. The gateway finds the node that runs
`StatusHandler` and casts to it. Sweep chunks are cast (no acknowledgement),
so the gateway is not blocked, but the router processes one chunk at a time.
Flow attribution, retained plugin results and endpoint inventory already
bypass the router mailbox through their own lanes; sweep results do not.

## Goals

- Use every core node for sweep ingestion.
- Preserve the ordering the ingestor depends on.
- Bound database concurrency explicitly.
- Keep ingestion semantics identical; change where it runs, not what it does.
- Never lose the ability to ingest if the new path is unavailable.

## Non-goals

- Making per-host ingestion cheaper. It remains the dominant cost and is a
  separate change (see Follow-ups).
- Durable delivery. Sweep chunks are volatile today (router mailbox, gateway
  in-memory buffer) and remain so.
- Changing the gateway or agents.

## Decisions

### 1. Keep the coordinator as the single admission point; move the work out

The dispatcher runs next to `StatusHandler` on the coordinator. One sender
means per-key message order is preserved end to end: the gateway preserves an
agent's order into `StatusHandler`, `StatusHandler` casts to the dispatcher,
and the dispatcher sends to one worker per key. Erlang guarantees ordering
per sender/receiver pair, including across nodes.

The dispatcher's per-chunk cost is one JSON decode to read `sweep_group_id`
plus a map update. That is a small fraction of a percent of the ingestion cost
it moves off the coordinator.

Alternative considered: let the gateway route straight to workers. That needs
the gateway to decode payloads and to track worker membership and load, and
spreads the ordering guarantee across several gateway replicas. Rejected.

### 2. Partition key `{agent_id, sweep_group_id}`

The ingestor has three ordering-sensitive steps:

- Execution rows are created on the first chunk and finalized on the final
  chunk; progress counters are incremented per chunk.
- Creating an execution marks every other running execution of the same group
  and agent as superseded.
- Per-agent availability keeps the newest `checked_at` per `(device, agent)`.

All three are scoped to one group on one agent, so that is the unit that must
stay ordered. Keying only by agent would also be correct but would serialize a
small group behind a large one on the same agent, which is the reported
symptom.

`agent_id` is the gateway-authenticated reporter on the status. A payload
that cannot be decoded gets `sweep_group_id = nil`; the worker then reproduces
the decode error exactly as the router does today.

### 3. Sticky while in flight, least-loaded when idle

The dispatcher tracks in-flight chunks per key and per worker, decremented by
an acknowledgement each worker sends after it finishes a chunk.

- A key with in-flight chunks is always sent to the worker that holds them.
  Moving it could let a later chunk overtake an earlier one.
- A key with nothing in flight is assigned to the worker with the fewest
  in-flight chunks. Ties prefer workers off the coordinator node (which already
  hosts the admission singletons), then a stable hash of key and worker.

This gives strict per-key ordering while letting load drift to whichever node
is least busy, including nodes that joined after startup.

Alternatives considered:

- **Horde-registered worker per key** (the pattern in `ingestion-routing` for
  sync). Workers would be created lazily per group and agent. Here the Horde
  CRDT syncs every few seconds and is tuned for stable singletons; a freshly
  started child is not visible for that long, inviting duplicate starts and
  name-conflict kills that drop mailboxes, and per-key churn bloats the CRDT.
  Concurrency would also scale with the number of groups times agents rather
  than with a bound we choose. Rejected.
- **Consistent hashing over workers.** Deterministic, but a membership change
  remaps keys that may have work in flight (breaking ordering), and a hot key
  cannot move off a busy worker. Rejected in favour of the in-flight tracking
  above.
- **JetStream work queue.** Would add durability, but sweep results are
  current-state writes to CNPG rather than telemetry routed through the event
  writer, per-key ordering needs extra machinery on top of a shared consumer,
  and it is a much larger change. Not pursued here.

### 4. Fixed pool per node, discovered with `:pg`

Each core node that handles agent results (`status_handler_enabled`) starts a
`:pg` scope and `workers_per_node` workers. The number of concurrent sweep
ingestions is therefore at most `nodes x workers_per_node`, each worker using
one connection from its node's Repo pool at a time. The default of 2 leaves
most of the default pool of 10 for other work. web-ng and agent-gateway nodes
do not enable status handling and host no workers.

`:pg` is part of OTP, needs no CRDT, reflects a local join immediately, and
removes a member when its process exits, including when its node disconnects.
The dispatcher subscribes with `:pg.monitor/2`.

### 5. Failure handling

- **Processor error or exception:** the worker catches it, logs the same
  warning the router logs, acknowledges the chunk, and stays alive.
- **Worker or node loss:** the leave notification clears that worker's keys.
  Their in-flight count is emitted as `lost` telemetry. This is the same loss
  the router mailbox has on a coordinator crash today; it is now visible and
  limited to one worker's queue.
- **No workers:** the dispatcher casts the chunk to `ResultsRouter`, which
  ingests it inline exactly as before. If the router is also absent the chunk
  is dropped with a warning and `dropped` telemetry, matching today's
  behaviour when the router is missing.
- **Dispatcher absent:** `StatusHandler` keeps the existing router path.
- **Synchronous `status_update` calls** keep the router path, since their
  contract is to reply after processing. The gateway casts sweep results.

### 6. Concurrency safety in the ingestor

Parallel workers can now touch the same device rows at the same time: two
agents sweeping the same devices, or one agent's overlapping groups.

- `ocsf_devices` updates (available, hysteresis, discovery source) select their
  target rows in a CTE with `ORDER BY uid FOR UPDATE`, so every statement locks
  in the same order and two ingestions cannot deadlock each other. The CTE
  also reads `was_available` under the row lock, which makes transition events
  accurate under concurrency. Each statement retries once on
  `deadlock_detected`, for interleavings with other writers of the table.
- Per-agent availability upserts are sorted by `(device_uid, agent_id)` so
  multi-row `ON CONFLICT` inserts acquire row locks in a consistent order. The
  existing `checked_at >=` guard keeps the newest observation regardless of
  which worker commits first.
- Hysteresis counters are read-modify-write inside a single `UPDATE`, so the
  row lock serializes concurrent increments.
- Provisional device creation already uses deterministic ids and a unique
  index; a concurrent duplicate is rejected and the following lookup finds the
  winner.
- Execution rows are only written by the key's own worker.

## Risks and trade-offs

- **More database concurrency.** Bounded by the pool size setting and visible
  through telemetry; set `SWEEP_INGESTION_WORKERS_PER_NODE` lower (or to 0,
  which disables the pool and restores the router path) if the database is the
  bottleneck.
- **Cross-node copies.** Each chunk is copied once from the coordinator to its
  worker's node. Chunks are a few megabytes at most and arrive at a low rate.
- **A single very hot key still runs serially.** One group on one agent is
  processed by one worker. Parallelising inside an execution would need a
  different completion protocol and is out of scope.

## Follow-ups

- Composite-check refresh enqueues one Oban job per device, one insert each;
  for a large chunk that is thousands of round trips and likely a large part
  of the per-host cost.
- Service-state publishing broadcasts the full sweep status, payload included,
  to every PubSub subscriber in the cluster.
