# Change: Make session sweep-lease re-issue cheap and bound the delivery lock

## Why

Every new agent control session re-issues the agent's whole sweep-lease window
(`LeasePass.refresh_agent` with `fresh: true`). Measured on demo 2026-11-10/11
after #6504: "Sweep lease refresh finished" took 169 s and 86 s for the two
agents with full 7-day horizons (2,009 and 2,015 unrun slots at refresh time
on a 5-minute schedule); every other agent took 2 ms to 683 ms. Per unrun slot
core re-signs ranges, rebuilds and re-verifies mapping evidence, and commits
one transaction per slot with ~8 round trips (`RecoveryAssignments.commit_issuance`
caps a batch at 4,096 entries but `LeaseDelivery.record_mappings` calls it once
per slot), plus several Ed25519 verifications. All of it runs inside
`:global.trans` on a per-agent delivery lock with infinite retries. The
5-minute `LeasePassWorker` (maintenance queue) takes the same lock in
`plan_group`; a stack dump showed it parked in `:global.set_lock` behind
session refreshes while holding a maintenance slot, and the queue made no job
attempt for ~22 minutes. The maintenance queue runs one slot per pod on demo
(three total) and is about 100 s behind because of the exposure snapshot
fan-out (separate change).

Two related defects ship with this work:

- `LeasePassWorker`'s cron uniqueness is `period: 240` on a `*/5` schedule, so
  a run older than 240 s no longer dedupes the next tick — the same lapse just
  fixed on the other workers, whose rule is now unique over pending states
  with no period.
- Two `LeasePassWorker` rows (max_attempts 1) sat in `executing` after their
  pods were replaced, `attempted_by` nodes no longer present; Oban's lifeline
  discarded the first about 4 hours after its attempt. They arise when a run
  outlasts `OBAN_SHUTDOWN_GRACE_PERIOD_MS` (60 s) at pod stop.

A side effect of the re-issue worth removing at the same time: same-value
issuance replay resolves `:committed` but still inserts duplicate
`recovery_assignment_issuances` rows on every reconnect, so the issuance
table grows with reconnects rather than with new authority.

## What Changes

- A session re-issue becomes verify-and-repair: when the slot issuance it
  would send is already recorded, still valid, AND the agent's session hello
  reports the same installed window digest core recorded, core skips the
  rebuild and the resend and reports the window verified current. Otherwise it
  rebuilds per group, commits issuance evidence in 256-entry batches instead
  of one transaction per slot, and sends exactly as today.
- The agent reports, per sweep group, a digest of the installed lease window
  it holds (it already persists it), in the session hello behind a
  capability. Core compares it with the acked digest: equal skips, different
  or absent for a leased group re-issues that group only. Agents without the
  capability get today's behavior (full re-issue on a new session), made
  cheaper by the batched commits. No agent is ever skipped on trust alone.
  The pre-skip state query is ruled out: the hello digest subsumes it.
- The delivery row records an authority fingerprint (issuer key id, contract
  identity, lease `issued_at`) at `record_push` time, so "still valid" is a
  cheap equality check. One new column plus a migration; written in the same
  transaction as the existing push record, no extra round trip.
- No caller waits on the per-agent delivery lock without a bound:
  `LeaseDelivery.serialize` takes explicit retries (default try-once) and the
  lease pass skips an agent whose delivery is in progress, picking it up next
  pass. A refresh that finds the lock held returns a bounded error for the
  gateway's existing backoff retry instead of parking.
- `LeasePassWorker` uniqueness becomes `period: :infinity` over
  `[:available, :scheduled]`, the rule the other workers now use.
- `LeasePassWorker` implements `OrphanRescue` with a sidecar-connection
  advisory-lock proof. The reaper-list registration lands after the in-gate
  cron-duplicates branch merges, on a branch cut after that merge (D2); the
  implementation and its tests land now.
- `LeasePassWorker` gets an execution timeout of 15 minutes (task 1.9):
  comfortably above any post-fix run (slowest measured full re-issue 169 s
  pre-fix; post-fix rebuilds are seconds), 16x under the 4-hour rescue. A
  timed-out run ends without leaving an `executing` row: the attempt is
  exhausted, locks release on death, partial evidence commits are harmless by
  replay idempotency, a recorded-but-unsent push is replaced because it is
  never acknowledged, and the next tick picks up.
- The two paragraphs in `add-edge-spool-recovery-coordinator/design.md` that
  specify "the full-window path, even when core holds a matching
  acknowledgement" and unbounded-lock delivery are updated to the new
  behavior, since that pending design would otherwise contradict this change.
  This is called out in the PR description as a change to that proposal too.

## Guarantees preserved

These hold by construction and were approved before build:

- An agent never runs a slot core has no issuance evidence for: the skip
  fires only on digest equality with the acked digest, and that digest was
  sent only after its evidence committed (`record_mappings` before
  `record_push` before send). Changed or first-issue windows take the full
  path unchanged.
- Core never believes an agent holds a window it does not: belief is digest
  equality against the agent's own hello report, never trust. A wiped store
  reports a different (or no) digest and gets a full re-issue; the tail only
  appends new slots, so without the digest check a wiped agent could sit days
  without sweeps.
- Issuance replay semantics are untouched: same value keeps the first
  evidence and resolves `:committed`; a conflicting value still halts the
  push before anything is sent.
- No verification is skipped: every committed entry still passes
  `verify_issuance` (Ed25519 over authority-signed claims). Only the
  transaction count drops, from one per slot to one per 256-entry chunk,
  and partial-chunk commits stay harmless exactly as today because replay
  resolves them `:committed`.
- Per-agent serialization is preserved: try-lock admits at most one
  deliverer per agent, and two concurrent passes stay complementary (the
  loser skips, the winner delivers; both compute from the same committed
  state).
- Nothing is truncated or dropped: the skip compares full content identity
  plus the hello digest, and batching commits the same entries.

## Decisions (approved)

- **D1 — hello digests, decided.** Accept-and-log is rejected: a skipped
  re-issue on trust alone leaves a store-wiped agent unleashed for slots
  already issued with nothing noticing, which is exactly what the session
  re-issue exists to cover. The agent protocol addition (proto + Go agent +
  gateway pass-through, capability-gated, mixed-version matrix in design §2)
  ships in this change.
- **D2 — registration deferred, decided.** No exception: the rescue
  implementation and tests land now, and the one-line reaper registration
  lands after `fix/disabled-assignment-results-and-cron-duplicates` merges,
  on top of staging. That file is not edited on a branch cut before the merge.
- **D3 — backstop timeout added as task 1.9, decided.** 15 minutes
  provisional; task 1.9 measures the post-fix pass over a 2,015-slot fixture
  and tightens the number with evidence.

## Impact

- Affected specs: `sweep-jobs` (re-issue skip with hello digest, bounded
  delivery lock), `job-scheduling` (cron uniqueness rule, LeasePass orphan
  rescue, worker execution timeout).
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/sweep_jobs/lease_delivery.ex`
  - `elixir/serviceradar_core/lib/serviceradar/sweep_jobs/lease_pass.ex`
  - `elixir/serviceradar_core/lib/serviceradar/sweep_jobs/lease_pass_worker.ex`
    (uniqueness, rescue implementation, timeout; NOT the reaper file)
  - `elixir/serviceradar_core/lib/serviceradar/sweep_jobs/sweep_lease_delivery.ex`
    (new fingerprint column)
  - `elixir/serviceradar_core/priv/repo/migrations/` (one migration)
  - Agent protocol: proto definition, Go agent hello + digest report,
    gateway session pass-through into the refresh path
  - `elixir/serviceradar_core/lib/serviceradar/jobs/reap_stale_periodic_jobs_worker.ex`
    (one-line registration — phase 2 only, after the in-gate merge)
  - `openspec/changes/add-edge-spool-recovery-coordinator/design.md`
    (two superseded paragraphs)
- Tests: DB tests for the skip predicate (including digest mismatch/absence
  and old-agent behavior) and batched commits, fail-first on `codex_*`
  scratch DBs or CI; unit tests for try-lock skip, the rescue proof both
  ways, the timeout; Go agent tests for the hello digest; gateway tests for
  pass-through; mixed-version cases. No live data; synthetic fixtures only.
- Off limits (untouched): the two in-gate branches and their files (reaper
  file until phase 2), Gemini's areas, serviceradar-control,
  serviceradar-ansible.
