# Change: Make Dgraph NIF calls asynchronous and bounded

## Why

Every Dgraph NIF was a blocking `DirtyIo` NIF that ran its RPC with
`block_on`. The upstream `dgraph-client` builds its tonic `Endpoint` with no
connect timeout, request timeout or keepalive, and offers no hook to set one.
So when Dgraph was black-holed or stalled, each concurrent call held one
dirty-IO scheduler indefinitely, and a dirty NIF cannot be cancelled from
Elixir. Topology projection issues calls per interface, per link, per MTR path
and per change. Once those calls held all of the dirty-IO schedulers (10 by
default), BEAM file I/O and every other dirty-IO NIF stalled node-wide.

A first attempt added deadlines plus an admission gate that refused calls
beyond a fixed count. That bounds the damage but still holds schedulers for up
to the deadline, and it drops writes under ordinary bursts. This change
replaces it.

## What Changes

- **Async NIFs.** Each Dgraph NIF in `dgraph_nif`, plus `topology_atlas_nif`
  `read_graph`, now runs on a normal scheduler. It validates its input, spawns
  the work onto the existing tokio runtime and returns `{:ok, ref, handle}`
  immediately. The task later sends
  `{:dgraph_nif_reply, ref, result, {kind, queue_wait_us, elapsed_us}}` to the
  caller through `OwnedEnv::send_and_clear`. A stalled Dgraph holds zero
  schedulers, however many calls are stalled.
- **Backpressure, not refusal.** A tokio `Semaphore` caps in-flight Dgraph
  calls at 8. Excess calls wait as cheap futures, and that wait counts against
  the call deadline.
- **Deadlines.** Connect is bounded at 10 s, single-item calls at 30 s, and
  whole-graph reads, pruning and the canonical rebuild at 300 s. A timeout
  returns `{:error, reason}`.
- **Cancellation without mailbox leaks.** `ServiceRadar.Dgraph.Call` waits
  with a selective `receive` for the deadline plus a margin. If no reply
  arrives it cancels the task through a resource handle. The task and the
  canceller race on one atomic state, so a cancelled call never replies, and
  a reply already claimed is collected before returning.
- **Bounded retry for idempotent upserts only.** Timeout and transient
  failures are retried with jittered exponential backoff, up to 3 attempts in
  total. Transient means an unreachable cluster, a transport failure, an
  aborted transaction or a cluster still starting, classified from the
  client's typed errors through a new `TopologyError::Transient`.
  `prune_stale`, `replace_hosted_edge`, `retire_hosted_edge`,
  `rebuild_canonical` and reads are not retried. If the last attempt fails,
  the caller gets `{:error, reason}`.
- **Telemetry.** New `:telemetry` events
  `[:serviceradar, :dgraph, :call, :stop | :timeout | :retry]` carry queue
  wait, latency, timeouts and retries.
- **Panic containment made explicit.** Every Bazel-built NIF now passes
  `-Cpanic=unwind` and rejects `panic=abort` with a `compile_error!`, as
  `prefix_tags_nif` already did. `bazel aquery` showed that rules_rs never
  applies the Cargo `[profile.release] panic = "abort"`: no NIF rustc action
  carries `-Cpanic=abort`. So shipped NIFs already unwind, and the claim that
  "any panic kills the BEAM" does not hold for Bazel-built NIFs. The change
  makes the invariant explicit, so that a future flag or a Cargo-driven build
  fails to compile instead of silently making panics fatal.
- The `ServiceRadar.Dgraph` facade keeps its `:ok | {:ok, _} | {:error, _}`
  contract, so callers do not change. The `Native` arities gain a trailing
  `deadline_ms` and the NIFs return a submission; only the facade and
  `TopologyAtlas.read_graph` call them.

## Impact

- Affected specs: `dgraph-client-nif` (introduced by the in-flight
  `replace-age-topology-with-dgraph`). This change adds requirements to it and
  supersedes that change's "Scheduler isolation" scenario, which assumed a
  `DirtyIo` NIF.
- Affected code: `elixir/serviceradar_core/native/dgraph_nif`,
  `elixir/serviceradar_core/native/topology_atlas_nif`, `rust/dgraph-topology`
  (error classification), `ServiceRadar.Dgraph`, `ServiceRadar.Dgraph.Call`,
  `ServiceRadar.Dgraph.Native`, `ServiceRadar.TopologyAtlas`, and the Bazel
  rustc flags of every NIF crate.
