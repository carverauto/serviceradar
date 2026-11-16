# Design: set-based sweep lease issuance and slot minting

## Context

`RecoveryAssignments.commit_issuance/1` is the issuer-only commit boundary for
historical assignment mappings. Its batch of 1..4,096 entries runs in one
transaction, and today it loops over the entries issuing:

| step | statement |
| --- | --- |
| ensure key | `INSERT key ON CONFLICT (mapping_key) DO UPDATE SET mapping_key = EXCLUDED.mapping_key` |
| lock key | `SELECT key ... FOR UPDATE` |
| record issuance | `INSERT issuance ON CONFLICT (mapping_key, mapping_value) DO UPDATE SET <identity> = EXCLUDED.<identity>` |
| read issuance back | `SELECT issuance WHERE mapping_key = $1 AND mapping_value = $2` |
| candidates | `SELECT candidates WHERE key_id = $1` + issuance load |
| replay | `SELECT resolutions WHERE key_id = $1 AND candidate_generation = $2` |
| append | `INSERT candidate ...`, `UPDATE key SET generation, selected_issuance_id, selection_generation` |

That is seven statements for a replay and eight for an append, per entry. The
lease delivery re-push of a full window is almost all replays.

`LeasePass.plan_agent/4` holds the sweep group row `FOR UPDATE` in a
transaction that mints up to `max_new_slots_per_assignment/0` (1,000) slots
with one `ExecutionSlots.schedule/4` insert each.

## Goals / Non-goals

- Goal: each transaction on these paths runs a number of statements that does
  not depend on how many rows it carries.
- Goal: outcomes identical to the per-entry loop for every batch.
- Non-goal: changing what is verified, what is stored, or any lookup,
  resolver or repair path. `lookup/3`, `repair/1`, `acquire_resolver/1` and
  `resolve/4` are single-key operations and keep their statements.

## Decision 1: commit_issuance reads, decides in memory, then writes

One call, inside the existing `RecoveryTransaction.run/2`:

1. Validate and encode every entry (`issuance_attributes/1`, unchanged, no
   database work). Deduplicate keys and `(key, value)` pairs in entry order,
   first occurrence wins.
2. **S1** ensure keys:
   `INSERT INTO keys (mapping_key) SELECT k FROM unnest($1::jsonb[]) ... ON CONFLICT (mapping_key) DO NOTHING`.
3. **S2** lock keys:
   `SELECT u.ord, k.* FROM unnest($1::jsonb[]) WITH ORDINALITY u(k, ord) JOIN keys ON mapping_key = u.k ORDER BY keys.id FOR UPDATE OF keys`.
4. **S3** record issuances: the same `unnest` insert over the distinct pairs
   with their first evidence, `ON CONFLICT (mapping_key, mapping_value) DO NOTHING`.
5. **S4** read issuances back by joining the distinct pairs on
   `(mapping_key, mapping_value)`, returning the pair ordinal.
6. **S5** candidates of the locked keys joined to their issuances, leaving
   out the evidence of issuances S4 already returned (a replay's candidate is
   its own issuance, and evidence is the bulk of every row);
   **S6** the locked keys' resolutions with outcome `selected`.
7. Fold the entries in order over that state in memory, exactly the per-entry
   decision (Decision 2). Stop at the first error.
8. **S7** insert the appended candidate memberships
   (`ON CONFLICT (key_id, issuance_id) DO NOTHING`) and **S8** update the
   final projection of every key the fold changed
   (`UPDATE keys ... FROM unnest(...)`). Each is skipped when empty.

At most eight statements plus `BEGIN`/`COMMIT` for any batch size. Every
statement passes its rows as one array per column, so the bind-parameter
count is fixed as well; nothing approaches PostgreSQL's 65,535-parameter
limit at 4,096 entries.

Matching rows to entries happens in SQL on `jsonb` equality (the ordinal
joins), the same operator the per-entry `mapping_key == ^key` filters used, so
no Elixir term comparison stands in for database equality.

**Why raw SQL rather than Ash actions.** The per-entry code used Ash
create/read/update actions. Their set equivalents need what Ash bulk actions
cannot express in a fixed number of statements: joins against `unnest ...
WITH ORDINALITY`, `FOR UPDATE` in key-id order, and an `UPDATE` with a
different value per row. `Ash.bulk_create` would also bind one parameter per
column per row and, with an empty `upsert_fields`, compiles to
`ON CONFLICT ... DO UPDATE` (see S1/S3 below). The four resources keep their
Ash definitions and the single-key paths keep using them. The resources'
only policy is "system actor", and `commit_issuance/1` is an internal,
issuer-only boundary with no user-facing caller, so no authorization decision
moves. The SQL lives in `RecoveryAssignments` next to the fold it serves.

**`DO NOTHING` instead of Ash's identity rewrite.** AshPostgres compiles an
upsert whose `upsert_fields` is empty to `DO UPDATE SET <identity> =
EXCLUDED.<identity>`, which rewrites (and row-locks) the existing key or
issuance row on every replay: a new tuple and WAL for no change. `DO NOTHING`
leaves the row alone. Nothing depends on that incidental lock: keys are locked
explicitly in S2, issuances are append-only and never updated, and candidate
membership is guarded by the key lock. `DO NOTHING` also tolerates duplicate
conflict keys within one statement, which `DO UPDATE` rejects.

## Decision 2: the in-memory fold is the per-entry algorithm

Per entry, in order, with `state` = the locked keys, their candidates (with
issuances) and their `selected` resolutions as read in S2-S6, plus whatever
earlier entries of this batch appended:

1. `issuance` = the S4 row for this entry's `(key, value)`; none is `:corrupt`.
2. `verify_issuance(issuance)` must pass (the stored row, which for a replay
   is the first evidence), else `:corrupt`.
3. `anchor` = this key's current in-memory projection; `existing` = its
   candidates. `length(existing) != anchor.generation` is `:missing` when
   there are none, `:corrupt` otherwise.
4. If `issuance.id` is already a candidate: `projection(anchor, existing,
   decisions at anchor.generation)` decides, unchanged: a resolved value equal
   to this entry's is `:committed`, a different one or an unresolved conflict
   is `:conflicting`, anything else is `:corrupt`.
5. Otherwise append: the candidate joins `existing`, the projection becomes
   `next_projection(anchor, issuance, existing)` (unchanged: the first
   candidate on a generation-0 key selects itself at selection generation 1;
   any later one clears the selection), and the entry is `:committed` if it
   was the first candidate, else `:conflicting`.

`projection/3`, `next_projection/3`, `selected_ids/1` and `verify_issuance/1`
are the same functions `lookup/3` and `resolve/4` use; the fold calls them on
structs shaped like the rows Ash returned (`%RecoveryAssignmentIssuance{}`,
anchor and decision maps with the same fields).

The batch result is the first error in entry order (and the transaction rolls
back), else `:conflicting` if any entry was, else `:committed`.

## Decision 3: why the outcomes are identical

The per-entry loop and the fold read the same data, apply the same pure
decision, and leave the same rows. Invariant by invariant:

| # | Per-entry invariant | Set form |
| --- | --- | --- |
| I1 | Batch of 1..4,096 entries; every entry validated, evidence encoded and bounded to 32 KiB before any database work, else `:invalid_issuance` | unchanged (`issuance_attributes/1`) |
| I2 | Each entry's key exists and is locked `FOR UPDATE` until commit | S1 over distinct keys, S2 locks every distinct key; the lock set held at commit is the same union |
| I3 | First evidence for a `(key, value)` is kept; a replay never rewrites it | S3 `DO NOTHING` over pairs deduplicated first-occurrence-first; the stored row read back in S4 is the same first row |
| I4 | The stored issuance must verify, else `:corrupt` | same `verify_issuance/1`, at the entry's position in the fold |
| I5 | Candidate-count fence: candidates == generation, else `:missing`/`:corrupt` | same check against the in-memory count, which includes earlier appends of this batch |
| I6 | Replay decision from the projection at the key's current generation | same `projection/3` over the S5/S6 rows filtered to the in-memory generation |
| I7 | Append: membership inserted, generation + 1, first candidate selects itself, later ones clear the selection | same `next_projection/3`; S7 inserts the memberships, S8 writes the key's final projection |
| I8 | `resolver_epoch` is never changed by a commit; an append fences captured `(epoch, generation)` tokens | S8 never touches `resolver_epoch`; the final generation equals the per-entry one, so `resolve/4` answers `:changed_candidates` exactly as before |
| I9 | Outcome: first error rolls back the batch; otherwise `:conflicting` if any, else `:committed`; processing continues past a conflict | the fold halts at the first error in entry order, before S7/S8; S1/S3 roll back with the transaction |
| I10 | Replaying a committed batch adds no rows and answers the same | S1/S3/S7 are `DO NOTHING`; the fold sees every candidate and replays |
| I11 | Issuances and candidates are append-only; competitors are never removed | no `DELETE`, and S8 updates only the key projection |

Reading once instead of per entry is sound because every writer of a key's
candidates, projection and resolutions holds that key's row lock: the commit
path (S2), `repair/1` (via `ensure_key`), `acquire_resolver/1` and
`resolve/4` (via `locked_key`). After S2 no other transaction can change what
S5/S6 read until this one commits, and within the transaction the only
changes are the fold's own, which it tracks. Statement order per key is
unchanged (ensure, lock, then record issuance), so the visibility of a
concurrently committed issuance is the same as before.

Intermediate projections of a key that a batch touches more than once are
invisible outside the transaction (the key is locked) and are overwritten by
the next entry inside it, so writing only the final projection leaves the same
row.

Differences that are not outcomes:

- Lock acquisition order is key-id order instead of entry order. The same
  locks are held; two concurrent batches over overlapping keys can no longer
  deadlock on opposite entry orders.
- A key's `updated_at` is set once per batch (one timestamp) rather than once
  per projection update.
- A batch that fails part-way has already run S1/S3 for later entries; they
  roll back with the batch, exactly as earlier entries' writes did before.
- Replays no longer rewrite key and issuance rows (`DO NOTHING`).

## Decision 4: chunking is by rows, not round trips

With a fixed statement count, the per-entry round-trip cost that forced 64-entry
chunks is gone. Chunking stays, for bytes and locks rather than time:

- evidence is up to 32 KiB per entry, so a chunk's S3 message, its WAL, and
  the decoded rows the fold holds scale with entries;
- every distinct key of a chunk stays row-locked until commit, which blocks
  `lookup/3` on those keys for the transaction's duration.

Once round trips are fixed, a chunk's duration is dominated by moving its
evidence: measured against the srql-fixtures database from a workstation, a
1,024-entry chunk took 2.4-3.8 s on a quiet machine and up to 10.7 s under
load, and a 512-entry chunk 0.7-1.0 s. `LeaseDelivery` therefore commits in
512-entry chunks: at most 16 MiB of evidence per transaction at the per-entry
cap (typical evidence is a few KiB), one transaction per ~256 slots, and eight
transactions for a full 4,032-entry window. `commit_issuance/1` keeps its
4,096-entry cap as the hard upper bound.
Partial commits stay harmless as before: a halted push leaves committed
chunks that the retry replays as `:committed`.

## Decision 5: slot minting is one insert per 250 rows

`ExecutionSlots.schedule_many/3` builds every slot's plan in memory (each
build failure is counted and skipped, exactly as a failed `schedule/4` was)
and inserts the built rows with `Ash.bulk_create/4` in batches of 250 rows.
`LeasePass` mints through it, so the 1,000-slot cap is at most four inserts.
250 rows bounds the statement size for groups with large plans (a plan page
holds up to 256 ranges, and every slot of a pass carries the same pages).

A database error on an insert aborts the `plan_agent` transaction, which rolls
back, exactly as a failing per-slot insert did (PostgreSQL refuses every later
statement of an aborted transaction, so the per-slot loop could never commit
past one either). `schedule/4` stays as the single-slot form and builds its row
with the same function.

## Statement bounds

| transaction | before | after |
| --- | --- | --- |
| `commit_issuance/1`, n entries | 7n-8n | <= 8 |
| full-window issuance (4,032 entries) | 63 tx x 448 | 8 tx x <= 8 |
| `plan_agent/4` minting m <= 1,000 slots | ~m + 8 | <= ceil(m / 250) + 8 |

## Risks

- A bug in the fold would mis-decide a whole batch at once. Mitigation: the
  fold calls the existing projection functions, and the mixed-batch tests
  assert the specified outcome of every entry kind and equality with
  committing the same entries one at a time.
- Larger chunks hold key locks longer than one 64-entry chunk did, but for
  milliseconds rather than seconds; lookups on those keys wait that long.
