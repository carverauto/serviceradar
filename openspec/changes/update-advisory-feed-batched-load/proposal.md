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
  never a torn one. While a run is in progress the served corpus mixes old and
  new advisory versions.
- `vulnerability_advisories` gains a dense bigint `ordinal`. A run records the
  ordinals it observes, written or skipped, in an in-memory chunked bitmap
  (`OrdinalSet`) instead of writing presence rows. An unchanged advisory
  produces no write.
- Finalization runs only after the run's completeness and distinct observed
  count validate. It promotes the run's new advisories and withdraws the feed's
  current advisories whose ordinal was not observed, each in batches that
  commit separately. A failed or incomplete run withdraws nothing.
- The loader stops writing and reading `advisory_feed_source_presence`. The
  table is left in place; dropping it is a follow-up.
- SRQL advisory rows omit `ordinal`, which is a loader-internal surrogate.

## Impact

- Affected specs: `advisory-feed-producers`
- Affected code: `AdvisoryFeeds.Loader`, new `AdvisoryFeeds.OrdinalSet`,
  `AdvisoryFeeds.FeedWorker`, SRQL `vulnerability_advisories`, two migrations.
- Two migrations add `ordinal` without rewriting the table in one statement:
  a metadata-only column and sequence default, then a backfill of existing
  rows in 5,000-row batches, a concurrently built unique index, and NOT NULL
  established through a validated check constraint. Until the backfill
  finishes, the loader numbers an unnumbered row it writes and withdraws an
  unnumbered current row it did not observe.
- A changed Ubuntu advisory committed by a run that later fails keeps its new
  assertions, which carry the unpromoted generation and read as stale rather
  than fresh until a later run promotes.
