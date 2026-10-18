## 1. Implementation

- [x] 1.1 Add `vulnerability_advisories.ordinal` in a metadata-only migration (sequence, nullable column, default for new rows) and advance `core.migrations.expectedVersion`.
- [x] 1.2 Commit each chunk in its own transaction; drop the run-wide transaction.
- [x] 1.3 Track observed advisories in an in-memory `OrdinalSet`; stop writing and reading source-presence rows.
- [x] 1.4 Promote and withdraw in bounded batches only after the run validates.
- [x] 1.5 Omit `ordinal` from SRQL advisory rows.
- [x] 1.6 Number an unnumbered row when a run writes it and withdraw an unnumbered current row a run did not observe, until the backfill job completes.
- [x] 1.7 Add `OrdinalBackfillWorker`, enqueued by that migration, to number existing rows in bounded batches after startup, build the unique index concurrently, and establish NOT NULL through a validated check, resumably and idempotently.

## 2. Verification

- [x] 2.1 Integration test: a run that fails partway withdraws nothing and leaves committed chunks whole.
- [x] 2.2 Integration test: a complete run withdraws exactly the absent advisories, in batches.
- [x] 2.3 Integration test: a steady-state run writes no advisory, coordinate, or presence rows.
- [x] 2.4 Integration test: each chunk is committed before the next chunk is read.
- [x] 2.5 Unit test: `OrdinalSet` membership and counting across word boundaries and sparse ordinals.
- [x] 2.6 Integration test: rows the backfill has not reached are numbered when observed and withdrawn when absent.
- [x] 2.7 Integration test: `OrdinalBackfillWorker` resumes a partial backfill without renumbering rows, leaves the column indexed and NOT NULL, and changes nothing when re-run.

## 3. Follow-up

- [ ] 3.1 Drop `platform.advisory_feed_source_presence` and its Ash resource once no deployed release writes it.
