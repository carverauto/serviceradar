# Change: Set-based sweep lease issuance and slot minting

## Why

Lease delivery and lease planning both run one SQL statement per row inside a
single transaction, so a transaction's duration is rows x statements-per-row x
the database round trip, and it holds one pooled connection the whole time
under the 15 s DBConnection checkout timeout.

- `RecoveryAssignments.commit_issuance/1` runs seven or eight sequential
  statements per entry (key ensure, key lock, issuance record, issuance
  read-back, candidate read and its issuance load, then the replay decision
  read or the candidate append and projection update). A full 7-day window on
  a 5-minute schedule is about 2,016 slots and 4,032 evidence entries. In
  256-entry chunks that was 1,792 statements per transaction, about 24 s at a
  10 ms round trip; CI timed out at `LeaseDelivery.commit_entry_chunks` inside
  `RecoveryTransaction.run`, and a failed chunk fails the whole push while the
  retry replays the same chunk. #6679 cut the chunk to 64 entries (448
  statements). That is a mitigation: time still scales with statements x
  round trip, and a 64-entry run has already failed on a degraded network.
- `LeasePass.plan_agent/4` mints up to 1,000 new slots per assignment with one
  `INSERT` each, inside the transaction that holds the sweep group row
  `FOR UPDATE`. At about 1,008 statements it is now the largest transaction
  on the path, measured at 11.7-45 s.

## What Changes

- `commit_issuance/1` becomes set-based. One call runs a fixed number of
  statements whatever its batch size (at most eight, plus `BEGIN`/`COMMIT`):
  ensure every distinct key, lock every distinct key `FOR UPDATE` in key-id
  order, record every distinct issuance, read the issuances back, read the
  locked keys' candidates and selected resolutions, then (only when there is
  something to write) insert the appended candidates and update the changed
  projections. The per-entry decision (replay, append, conflict, corrupt,
  missing) is computed in memory by folding the batch in entry order over the
  state read under the key locks, using the same projection functions the
  lookup and resolver paths use. Each statement takes its rows as `unnest`
  arrays, so its parameter count is fixed too.
- The per-entry statement loop is removed. There is no dual path and no flag;
  single-entry callers (output grants, recovery authorization) use the same
  set-based commit.
- Lease delivery commits issuance evidence in 512-entry chunks, sized by rows
  to bound per-transaction evidence bytes and row locks, not by round trips.
  A 4,032-entry window commits in eight transactions of at most ten
  statements each (measured 0.7-1.0 s each against the fixture database),
  instead of 63 transactions of 448 statements, one of which overran the 15 s
  checkout timeout in the same measurement.
- Lease planning mints new slots with a bulk insert of at most 250 rows per
  statement, so the 1,000-slot cap is at most four inserts instead of 1,000.
- The pending change `fix-sweep-lease-reissue-stall` specifies 64-entry
  batches; its scenario and design text now defer the batch shape to this
  change, so archiving it cannot restore the 64-entry wording.

## Guarantees preserved

Semantics are identical to committing the same entries one at a time, in
order, inside one transaction (design.md has the per-invariant argument):

- the same entries are accepted, replayed, appended, reported conflicting, or
  refused, with the same batch outcome (`:committed`, `:conflicting`, or the
  first error in entry order, which rolls the whole batch back);
- same-value replay keeps the first issuance evidence and adds no rows;
- a differing value is retained as a conflicting candidate and quarantines the
  projection; resolver fences (`resolver_epoch`, candidate generation) move
  exactly as before;
- evidence is still committed before `record_push` and the send, and a
  conflicting entry still halts the push before anything is sent;
- every stored issuance an entry touches is still verified before its
  outcome counts.

## Impact

- Affected specs: `edge-producer-data-plane` (set-based issuance commit),
  `sweep-jobs` (statement-bounded issuance and minting transactions).
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/edge/recovery_assignments.ex`
  - `elixir/serviceradar_core/lib/serviceradar/sweep_jobs/lease_delivery.ex`
  - `elixir/serviceradar_core/lib/serviceradar/sweep_jobs/lease_pass.ex`
  - `elixir/serviceradar_core/lib/serviceradar/sweep_jobs/execution_slots.ex`
  - `openspec/changes/fix-sweep-lease-reissue-stall/` (batch wording)
- No migration: the existing unique indexes on keys, issuances and candidate
  membership already back the set-based `ON CONFLICT` targets.
- Tests: mixed-batch outcome tests (valid, duplicate, replayed, stale,
  conflicting and fenced entries, plus missing and corrupt batches) asserted
  against the specified outcomes and against committing the same entries one
  at a time; a statement-count test using Repo query telemetry; the 2,016-slot
  serial re-push test bounds commits and statements.
