## Context

`ServiceRadar.Dgraph` is the single Elixir facade over the Dgraph NIF. Callers
include per-interface and per-link topology upserts, MTR path projection, the
network-change projector, hypervisor enrichment, pruning, the canonical
rebuild, and the topology atlas world build (`read_graph`). The upstream
`dgraph-client` connects lazily through a tonic `Endpoint` that it builds
itself, with no timeout and no keepalive.

## Goals / Non-Goals

- Goals:
  - no BEAM scheduler is held while Dgraph is slow, stalled or black-holed;
  - every call ends by a deadline;
  - load on Dgraph is bounded by backpressure, not by dropping calls;
  - a cancelled caller never gets a late message;
  - transient failures of idempotent writes heal without caller changes.
- Non-Goals: changing the upstream client, changing call semantics or result
  shapes, adding a Dgraph connection pool.

## Decisions

- **Reply by message from the tokio runtime.** A NIF returns
  `{:ok, ref, handle}` and the task replies with
  `OwnedEnv::send_and_clear`. That call is legal only on a thread the VM does
  not manage, which the tokio workers are not. Rejected alternative: a
  per-call deadline on the existing blocking dirty NIFs. That still holds one
  scheduler per call for up to the deadline.
- **Semaphore inside the deadline.** A permit is acquired inside the timed
  future, so queue wait counts against the deadline and a call queued past it
  fails as `timeout ... waiting for an in-flight slot`. Per-item calls
  share 8 slots; whole-graph reads and pruning draw from a separate pool of
  2 (the `stale_canonical_keys` read in a canonical rebuild too), so long
  bulk calls cannot take the slots per-item writes need, and a burst of
  item writes cannot starve bulk work.
  The limits are sized for Dgraph and not tied to any scheduler count.
- **Caller exit cancels.** The call handle is a monitored resource: the NIF
  monitors the calling process at submit and the resource's `down` callback
  cancels the call, so an abandoned call releases its slot at once instead of
  holding it until its deadline (up to 300 s for bulk work).
- **Cancel/reply race on one atomic.** The handle holds `RUNNING`,
  `REPLYING` or `CANCELLED`. The task moves it to `REPLYING` before sending;
  `cancel` moves it to `CANCELLED` and aborts the task. If cancel loses, the
  reply is in flight and the Elixir side collects it, bounded by a short
  receive. This is what makes "no mailbox leak" deterministic rather than
  timing-dependent.
- **Panic isolation at the poll boundary.** The task future is polled inside
  `catch_unwind`. A panic becomes a `:panic` reply rather than a dead task
  that leaves its caller waiting until the backstop.
- **The retry decision stays in Elixir.** The native side classifies each
  attempt as `:ok | :timeout | :transient | :error | :panic`. The facade
  decides per operation whether a repeat is safe. Keyed upserts (device,
  interface, prefix, prefix attachment, change, hop, edge, canonical edge,
  canonical telemetry, MTR path) are idempotent. These are not retried:
  `prune_stale`, whose count changes on a repeat; `replace_hosted_edge` and
  `retire_hosted_edge`, which are guarded by the observation timestamp a
  concurrent refresh can move; and reads. Canonical rebuild chunks
  (`upsert_canonical_edges`, `delete_canonical_edges`) are idempotent and are
  retried.
- **Typed transient classification.** `TopologyError::Transient` is set from
  the client's own `is_transport` / `is_aborted` / `is_cluster_not_ready`
  predicates, and connect failures count as transient. Nothing matches on
  message text.

- **Canonical rebuild is chunked, Elixir-driven and resumable.** It used to
  issue one RPC per edge under one 300 s deadline, so on a large graph it
  timed out every run after the upserts and before the stale deletes.
  `ServiceRadar.Dgraph.CanonicalRebuild` now orders the desired edges by a
  deterministic term encoding and drives two phases. **upsert** writes chunks
  of up to 200 edges per Dgraph transaction through
  `upsert_canonical_edges/3` (per-chunk item deadline, retried as an
  idempotent write). **delete** runs one whole-graph `stale_canonical_keys/3`
  read, then `delete_canonical_edges/3` in chunks of up to 200. There is no
  deadline over the whole rebuild.
- **The rebuild cursor lives in CNPG.** `platform.dgraph_canonical_rebuild_cursors`
  holds one row per rebuild name: the desired-set fingerprint (SHA-256 of the
  ordered set), the phase, and the next upsert chunk. It is written after
  every upsert chunk and on entering the delete phase. A run whose fingerprint
  differs ignores the row and starts at chunk 0, because chunk boundaries over
  a different set mean nothing. The delete phase records no position: it
  recomputes the stale keys from Dgraph, and deletes are idempotent. A fully
  successful run deletes the row, then reconciliation is enqueued. Rejected
  alternatives: progress in process memory (lost on restart) or in Dgraph (the
  store being rebuilt); scaling the 300 s deadline with edge count (keeps one
  RPC per edge and still fails late).

## Risks / Trade-offs

- An idempotent upsert that keeps timing out can occupy its caller for up to
  three times the item deadline, plus backoff. The caller is a process, not a
  scheduler, and the result is still `{:error, _}`.
- With no scheduler held, a burst can queue more calls than before. They wait
  as futures and fail at their deadline, so the queue is bounded in time,
  not in count.

## Migration Plan

This is internal to the NIF and its facade, and the public facade contract
is unchanged. Rollback is a revert of this change.

## Open Questions

- None.
