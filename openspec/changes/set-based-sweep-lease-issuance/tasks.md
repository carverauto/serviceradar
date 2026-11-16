# Tasks: set-based-sweep-lease-issuance

## 1. Spec

- [x] 1.1 Proposal, design (per-invariant equivalence argument, statement
      bounds, chunk sizing) and spec deltas for `edge-producer-data-plane` and
      `sweep-jobs`.
- [x] 1.2 Update the pending `fix-sweep-lease-reissue-stall` batch scenario and
      design text so archiving it cannot restore the 64-entry wording.
- [x] 1.3 `openspec validate set-based-sweep-lease-issuance --strict`.

## 2. Tests first

- [x] 2.1 Mixed-batch DB test: valid, intra-batch duplicate, same-value
      replay, differing value for a committed key, two differing values for a
      new key, stale (unselected) replay, and fenced (captured resolver token)
      entries in one batch; assert each key's specified outcome and equality
      with committing the same entries one at a time. Run it against the
      per-entry implementation first: it must pass there (characterization).
- [x] 2.2 Missing-membership and corrupt-evidence batches answer the first
      error and commit nothing.
- [x] 2.3 Statement-count test using Repo query telemetry: batches of 1, 64
      and 256 new entries, and a 256-entry replay, issue the same number of
      statements, at most eight plus transaction boundaries (measured 10 for a
      new batch of any size, 8 for a replay). Against the per-entry
      implementation the 256-entry batch could not finish inside the
      connection timeout.
- [x] 2.4 Serial 2,016-slot re-push test: issuance commits at most eight plus
      bookkeeping, and the refresh's and the minting pass's total statements
      bounded (measured 81 and 75).

## 3. Implementation

- [x] 3.1 `RecoveryAssignments.commit_issuance/1`: S1-S8 set statements and
      the in-memory fold over the existing projection functions; remove the
      per-entry loop.
- [x] 3.2 `LeaseDelivery`: 512-entry chunks (1,024 measured 2.4-10.7 s per
      chunk against the fixture; 512 measured 0.7-1.0 s).
- [x] 3.3 `ExecutionSlots.schedule_many/3` (250-row bulk inserts) and
      `LeasePass` minting through it.

## 4. Proof and landing

- [x] 4.1 Run the touched DB tests on a srql-fixtures scratch database; record
      the 2,016-slot re-push time before and after; drop the database. Before
      (staging, 64-entry chunks): minting 451 s, the re-push failed at 17 s on
      the checkout timeout. After: the whole test 24.6 s, the re-push 7.9 s
      with eight 0.7-1.0 s chunk transactions.
- [x] 4.2 Format, Credo, and no compile warnings in the touched files (the
      app has unrelated pre-existing warnings, so `--warnings-as-errors`
      fails on staging too).
- [ ] 4.3 Land through the no-mistakes gate; Core Integration green.
