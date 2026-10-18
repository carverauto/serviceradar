# Change: Commit advisory feed loads in bounded batches

## Why

`Loader.load_and_finalize/2` ran a whole feed run in one transaction. A first
full nist-nvd2 rewrite is about 0.93 GB of JSON inside that one transaction, and
every run, including one where nothing changed, wrote a source-presence row for
each of roughly 409k source objects so that finalization could tell which
current advisories were absent from the snapshot. A steady-state run therefore
produced hundreds of thousands of rows of WAL to record that nothing changed.

## What Changes

- Each chunk of changed advisories commits in its own transaction. An advisory
  row commits with its complete coordinate, configuration, and assertion
  replacement, so a reader sees an old or a new version of each advisory and
  never a torn one. For every provider, KEV included, a chunk holds at most
  2,000 records and 16 MiB of serialized records; a single record larger than
  16 MiB commits alone in its own chunk, since splitting it would tear the
  advisory. While a run is in progress the served corpus mixes old and new
  advisory versions.
- `vulnerability_advisories` gains a dense bigint `ordinal`. A run records the
  ordinals it observes, written or skipped, in an in-memory chunked bitmap
  (`OrdinalSet`) instead of writing presence rows. An unchanged advisory
  produces no write.
- Finalization runs only after the run's completeness and distinct observed
  count validate. It promotes the run's new advisories and withdraws the feed's
  current advisories whose ordinal was not observed, each in 1,000-row batches
  that commit separately. A failed or incomplete run withdraws nothing.
- The loader stops writing and reading `advisory_feed_source_presence`. The
  table is left in place; dropping it is a follow-up.
- SRQL advisory rows omit `ordinal`, which is a loader-internal surrogate.

## Impact

- Affected specs: `advisory-feed-producers`
- Affected code: `AdvisoryFeeds.Loader`, new `AdvisoryFeeds.OrdinalSet`,
  new `AdvisoryFeeds.OrdinalBackfillWorker`, `AdvisoryFeeds.FeedWorker`, SRQL
  `vulnerability_advisories`, one migration.
- `ordinal` is added without rewriting or long-locking the table. The
  migration is metadata only: a sequence, a nullable column, and a default
  for new rows. It enqueues `OrdinalBackfillWorker`, an idempotent Oban job
  on the `maintenance` queue that runs after startup and numbers existing
  rows in 5,000-row transactions, builds the unique index concurrently, and
  establishes NOT NULL through a validated check constraint. A retry resumes
  where an interrupted attempt stopped. Until the job finishes, the loader
  numbers an unnumbered row it writes and withdraws an unnumbered current
  row it did not observe.
- A changed Ubuntu advisory committed by a run that later fails keeps its new
  assertions, which carry the unpromoted generation and read as stale rather
  than fresh until a later run promotes.
