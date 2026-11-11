# Design: cheap session re-issue with a bounded delivery lock

## Context

`LeasePass.refresh_agent/3` runs on every new agent control session with
`fresh: true`, which forces `LeaseDelivery.deliver` down the `full()` path:
re-sign every range, rebuild and re-verify every slot's mapping evidence, one
`RecoveryAssignments.commit_issuance` transaction per slot (~8 round trips
each), then `record_push` and send — all inside `:global.trans` on the
per-agent delivery lock with infinite retries. For a full 7-day horizon that
is ~2,009–2,015 slots and 86–169 s of lock hold, during which the 5-minute
`LeasePassWorker` parks in `:global.set_lock` holding a maintenance slot
(demo: one slot per pod, three total, queue ~100 s behind).

## Decisions

### 1. Skip predicate: identical window, proved by digest equality

Ed25519 signatures are deterministic, capability claims derive entirely from
stored rows (assignment, slots, contract, key, `issued_at`, and for a re-issue
of the same lease `issued_at` is the recorded `lease_issued_at`, not now), and
proto encoding is deterministic. So a re-push of unchanged inputs is
byte-identical, and "unchanged" is provable by comparing inputs.

In `LeaseDelivery.deliver`, on the `fresh: true` path, after planning the full
window, return `{:ok, :up_to_date}` without rebuilding when ALL hold:

- the plan targets the same `lease_id` as the delivery row (any fence, epoch
  bump, or revocation changes the id and forces the full path);
- the delivery row shows an installed ack on the delivered digest
  (`ack_installed` with `acked_payload_sha256 == delivered_payload_sha256`);
- every unrun slot carries a `delivered_at` mark, the cursor equals the
  carried end of the unrun set, no slot was dropped since its mark, and the
  check set is unchanged (the existing `deliver` filters already compute all
  of these);
- the freshly computed authority fingerprint equals the fingerprint stored by
  the last `record_push`: issuer key id, contract id/version/bundle digest,
  registry epoch/snapshot digest, lease `issued_at`;
- the session hello reports, for the group, the digest of the window the
  agent has installed, and it equals the acked digest.

The ack chain is inductive: `plan()` only takes the tail path when the
previous push was acked-installed, so an installed ack on the latest digest
implies the agent installed every push that built the current window. The
digest equality is what turns that implication into a check: core believes
the agent holds a window if and only if the agent's own report matches the
recorded ack. The agent persists installed leases across restarts with merge
semantics and re-installs identical bytes idempotently, so a skipped resend
changes nothing on the agent; a wiped store reports a different (or no)
digest and gets a full re-issue for that group only. The skip logs at info
with group and digest.

First-issue and changed-window refreshes are unaffected: no ack, or any
predicate miss, takes today's full path. Agents without the hello capability
take today's full path per group (cheaper via §3 batching); the skip never
fires on trust alone.

The pre-skip state query is ruled out: the hello digest subsumes it. It is
fresher (session start, no extra round trip under or before the lock) and it
answers the exact question — possession — where a core-side query can only
re-assert core's own records.

### 2. Hello digest protocol (agent addition, in this change)

- The agent reports per sweep group the SHA-256 of the installed lease
  payload bytes — the same digest it acked with `installed: true` — in the
  session hello (or the first control message where hello cannot carry it),
  behind the capability `sweep_lease_hello_digests:v1`. Absent group
  means the agent holds nothing for that group.
- Proto, Go agent, and gateway pass-through ship together: the gateway
  session carries the reported map into the refresh path (`refresh_agent`
  gains the reported digests; absent by default, which forces the full path).
  The map is authoritative only when the same hello advertises the
  capability: without it the gateway forwards an empty map, and core
  normalizes a malformed map to empty, so both layers fail closed to the
  full path.
- Skip is core's invisible optimization: agents MUST NOT assume it and observe
  no behavior change, because a re-push of identical content re-installs and
  re-acks idempotently through the existing merge path.
- Mixed-version matrix (all specified, all tested):
  - new agent + new core, capability present: per-group digest check;
    equal skips, different or absent re-issues that group only;
  - old agent (no capability) + new core: no digests; full re-issue per
    group with batched commits;
  - new agent + old core/gateway: the hello field is ignored (proto3
    unknown-field tolerance; the old gateway does not forward it); full
    re-issue. The agent never waits for or depends on a skip.

### 3. Batching: build all entries, commit in 256-entry chunks

`record_mappings` keeps its per-slot evidence construction (including every
`verify_issuance` check) but returns entries instead of committing per slot;
a new step commits the concatenated entries in 256-entry chunks through the
existing `commit_issuance` (whose 4,096-entry cap is now just an upper bound),
so a 2,015-slot window commits in ~16 transactions instead of ~2,015. Chunks
stay small enough that every commit fits the checkout timeout even on a loaded
executor — CI proved a whole-window single transaction does not fit. A
conflicting entry still halts the push before `record_push` and the send,
exactly as today; partial-chunk commits resolve `:committed` on retry through
the untouched replay path.

`mark_carried` is already a bulk update and stays as-is. The per-slot
`source_authorizations` signatures stay per-slot (CPU-cheap, no round trips).

### 4. Bounded lock: try-once by default, skip on contention

`LeaseDelivery.serialize/3` gains explicit retries with a try-once default
(`:global.trans(id, fun, nodes, 0)` answers `:aborted` when another process holds
the lock, instead of queueing behind it; a deadlock or node-loss abort answers
`{:aborted, reason}` — both are handled as busy). No caller passes an unbounded retry:

- `plan_group` (lease pass): on a busy abort the agent is skipped for
  this pass with a debug log naming agent and group; the next pass (5 min)
  picks it up. Starvation is implausible — the lock holder is a rare
  session refresh, minutes at most pre-fix and seconds post-fix — and a
  skipped agent loses nothing because delivery state is untouched.
- `refresh_agent` / `LeaseRefresh`: on a busy abort return
  `{:error, :delivery_in_progress}` for the gateway's existing bounded
  backoff retry. The session never parks on the lock.
- Revocation sends take the same try-lock; a busy agent's revocation is
  retried by the next pass (revocation intent persists in the row state).

Caveat carried into implementation: only lock contention may surface as an abort
on this path — the deliver bodies use `with`, never `throw`, so a logic abort
cannot masquerade as "busy". Verified against OTP: the abort is the `:aborted`
atom on contention and `{:aborted, reason}` on deadlock or node loss, and a
raise inside the body propagates. A unit test pins both sides (contention
aborts promptly; logic error propagates).

### 5. Cron uniqueness: pending states, no period

`LeasePassWorker` becomes
`unique: [period: :infinity, states: [:available, :scheduled]]`, the rule the
other workers now use (and the in-gate reaper's own new rule). Rationale over
the `:incomplete` variant: an orphan `executing` row must never again block
ticks for hours, and overlap is safe here — the pass is idempotent and
per-agent delivery serializes through the try-lock (concurrent passes stay
complementary). The 4-hour age sweep remains the fallback.

### 6. Orphan proof: sidecar connection holding a session advisory lock

`LeasePassWorker` implements `OrphanRescue`. On perform start it opens a
dedicated Postgrex connection (outside the pool, owned by the job process)
and takes a session-level advisory lock on a stable key; it unlocks and
closes in an `ensure` block. Death of the process or node closes the socket
and PostgreSQL releases the lock — this covers the observed orphan source,
runs outlasting the 60 s shutdown grace at pod stop. A netsplit keeps a truly
live holder's socket open, so the proof never false-positives into a double
run. The pool is never polluted because the lock never lives on a pooled
connection.

`rescue_orphaned/1` selects this worker's `executing` rows past a 60-second
grace (covers only the mark-executing-to-lock window), attempts the same
advisory lock with `pg_try_advisory_lock`, rescues rows whose lock is free,
and leaves the rest. Failures return `{:error, _}` without raising, per the
behaviour. Registration in `orphan_rescue_workers/0` is phase 2 by D2:
it lands after `fix/disabled-assignment-results-and-cron-duplicates` merges,
on top of staging; the implementation and its tests land in phase 1 and the
reaper file is not edited on a branch cut before that merge.

### 7. Execution timeout: 15 minutes, provisional

`LeasePassWorker` gets `timeout: 15 * 60_000`. Rationale: the slowest
measured full re-issue is 169 s pre-fix; post-fix rebuilds are seconds
(batched single-transaction commits) and a whole pass over all agents stays
well under 5 minutes, so 15 minutes is comfortable headroom at 16x under the
4-hour rescue. Task 1.9 measures the post-fix pass over a 2,015-slot fixture
and tightens the number with evidence.

Timeout semantics (specified, then tested): Oban kills the run; the attempt
is exhausted (`max_attempts: 1`) into a terminal row — never left
`executing` for the age rescue. `:global` and advisory locks release on
death. Half-issue is impossible by construction: each agent's delivery
commits evidence before its send, a recorded-but-unsent push is replaced
because it is never acknowledged, and partial evidence commits resolve
`:committed` on the next attempt through the untouched replay path. The next
tick enqueues normally because uniqueness covers only pending states.

### 8. Superseded pending design text

`add-edge-spool-recovery-coordinator/design.md` specified the full-window
path "even when core holds a matching acknowledgement" and unbounded-lock
delivery as the mechanism that makes "the last recorded push the last one
sent". Both statements are replaced: the skip reuses the push only on
provable identity plus digest equality, and ordering across concurrent
deliverers comes from the try-lock plus the ack chain, not from indefinite
mutual exclusion. No spec deltas of that change repeat the statements
(checked), so only the two design paragraphs change; the PR description calls
this out as a change to that proposal too.

## Consequences

- Session re-issue on an unchanged window with a capable agent costs a plan
  plus comparisons: milliseconds instead of minutes. Changed windows cost
  one batched commit instead of thousands of transactions; old agents keep
  today's sends at the batched cost.
- The maintenance queue can no longer stall behind one agent's delivery:
  every lock wait is bounded, the pass degrades to skipping one agent for
  one pass, and no run outlives its timeout.
- `recovery_assignment_issuances` stops growing on reconnects.
- One migration (fingerprint column, backfilled NULL meaning "unknown:
  rebuild once"). NULL fingerprints never match, so rollout is safe mid-run.
- Agent protocol grows one hello field behind one capability, with the
  mixed-version matrix above. No agent-visible behavior change.
- Telemetry: skip log line with group and digest; skipped-agent debug line;
  rescued orphan report through the existing reaper telemetry.

## Alternatives considered

- Accept-and-log skip (trust the ack record): rejected in D1 — a wiped
  store stays unleashed for already-issued slots with nothing noticing, and
  the tail only appends new slots, so the exposure lasts days. The digest
  turns the assumption into a check.
- Heartbeat column instead of the sidecar lock: still an age rule with a
  shorter fuse, and shares the netsplit false-positive the repo rejected.
  Not proposed.
- No timeout (lock bound suffices): rejected in D3 — a slotless queue with
  one slot per pod needs the backstop; the timeout is specified to leave no
  orphan behind.
