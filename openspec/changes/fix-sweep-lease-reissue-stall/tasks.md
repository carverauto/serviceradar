# Tasks: fix-sweep-lease-reissue-stall

Spec and design change only until the approved decisions below are folded in;
they now are (D1 hello digests, D2 deferred registration, D3 timeout).
Implementation runs in two phases: phase 1 now (everything except the reaper
one-liner), phase 2 after `fix/disabled-assignment-results-and-cron-duplicates`
merges (rebase onto staging, add the registration, revalidate).

## 1. Spec (done, then revalidated after the decision fold-in)

- [x] 1.1 Amend `sweep-jobs` with the re-issue skip and bounded delivery
      lock requirements and scenarios.
- [x] 1.2 Amend `job-scheduling` with the cron uniqueness rule, the LeasePass
      orphan-rescue requirements, and the execution-timeout requirement.
- [x] 1.3 Run `openspec validate --strict` for the change and fix every
      reported problem.
- [x] 1.4 Grep `openspec/` for every requirement bullet the deltas touch and
      confirm no pending (non-archive) delta repeats superseded wording;
      update the two `add-edge-spool-recovery-coordinator/design.md`
      paragraphs.

## 2. Delivery skip and batching (phase 1)

- [x] 2.1 Migration: `authority_fingerprint` column on the sweep lease
      delivery resource (NULL means unknown: rebuild once). Platform schema
      only.
- [x] 2.2 `LeaseDelivery.deliver`: implement the design §1 skip predicate on
      the `fresh: true` path, including hello-digest equality per group;
      return `{:ok, :up_to_date}` with an info log carrying group and digest.
      Fail-first DB tests: unchanged window + matching digest performs zero
      signs, zero issuance writes, zero sends; digest mismatch, absent
      digest, and old-agent (no capability) each take the full path.
- [x] 2.3 `LeaseDelivery.record_mappings`: build entries for all slots,
      commit in 256-entry chunks (each commit fits the checkout timeout; CI
      proved a whole-window single transaction does not); preserve
      halt-before-send on conflict and
      all `verify_issuance` checks. Fail-first DB test (unboxed, serial lane):
      a 2,015-slot window's re-push issues a bounded handful of `commit`
      queries counted client-side via Ecto telemetry; a conflicting entry
      still blocks the send. (`pg_stat_database` is unsound here: inside the
      sandbox every inner transaction is a savepoint, and the fixture
      server's stats collector lags commits by tens of seconds.)
- [x] 2.4 `LeaseDelivery.record_push`: store the fingerprint in the same
      transaction. Fail-first DB test: fingerprint round-trips and NULL never
      matches.

## 3. Bounded lock (phase 1)

- [x] 3.1 `LeaseDelivery.serialize`: explicit retries, try-once default.
      Unit test: contention aborts promptly (`:aborted`); logic errors propagate.
- [x] 3.2 `LeasePass.plan_group` / `lease_agent`: skip busy agents with a
      debug log; next pass picks them up. Fail-first test with a lock holder.
- [x] 3.3 Refresh path: map busy to `{:error, :delivery_in_progress}` for
      the gateway backoff. Test the session-visible result.
- [x] 3.4 Audit every remaining `serialize` caller for an explicit retry
      choice; none waits unboundedly.

## 4. Worker hygiene (phase 1 implementation, phase 2 registration)

- [x] 4.1 `LeasePassWorker` uniqueness to
      `period: :infinity, states: [:available, :scheduled]`. Regression test:
      a slow run admits no duplicate tick; an orphan `executing` row blocks
      no tick.
- [x] 4.2 `OrphanRescue` implementation for `LeasePassWorker` (sidecar
      connection + session advisory lock, 60 s grace). Unit test the proof
      both ways: dead holder rescues, live holder is left alone.
- [x] 4.3 Phase 2 only, after the in-gate cron-duplicates branch merges and
      on top of staging: register in `orphan_rescue_workers/0`. Do not edit
      that file on a branch cut before the merge. Reaper test covers the
      rescued row.

## 5. Hello digest protocol (phase 1)

- [x] 5.1 Proto: per-group installed-window digest map on the session hello
      (or first control message), capability-gated. Unknown-field tolerance
      keeps old core/gateway safe.
- [x] 5.2 Go agent: report the installed payload digest per group from the
      persisted lease store; absent group means held nothing. Agent tests
      with synthetic leases. Skip stays core-side and invisible: duplicate
      pushes still re-install and re-ack idempotently.
- [x] 5.3 Gateway pass-through: session carries the reported map into the
      refresh path; `refresh_agent` gains the reported digests (absent by
      default forces the full path). Gateway tests.
- [x] 5.4 Mixed-version matrix tests: new/new skips per group, old agent
      rebuilds, new agent/old core rebuilds.

## 6. Timeout backstop (phase 1, task 1.9)

- [x] 1.9 `LeasePassWorker` timeout 15 minutes provisional: measured the
      post-fix re-push over a 2,016-slot fixture (serial lane,
      `lease_window_commit_serial_db_test`, green in 938 s end-to-end with a
      bounded handful of commits; a chunk-size-4 sensitivity run measured
      exactly 1,010 commits, proving the counter tracks `commit_issuance`).
      15 minutes stays provisional — comfortably above any measured single-agent
      post-fix refresh — pending post-merge demo timing to tighten. Test: a
      killed run ends in a terminal row (never `executing`), locks release,
      partial state resumes cleanly on the next tick.

## 7. Landing

- [ ] 7.1 Full verification: touched-area `make test` path, contract test,
      quality gates, then the no-mistakes gate (reviewer not claude).
- [ ] 7.2 Phase-2 rebase + registration + revalidation after the cron
      branch merges.
- [ ] 7.3 PR description calls out the `add-edge-spool-recovery-coordinator`
      design edit as a change to that proposal too. Merge with `--merge`.
