defmodule ServiceRadar.Inventory.AdvisoryFeeds.OrdinalBackfillWorker do
  @moduledoc """
  Numbers advisory rows that predate `vulnerability_advisories.ordinal`, then
  indexes and constrains the column, without any statement that rewrites or
  long-locks the whole table.

  - Rows are numbered from the column's sequence in batches of 5,000 keyed by
    primary key, each batch its own transaction, so the WAL is spread over
    many small commits. Rows inserted meanwhile already take the default.
  - The unique `(provider, feed_key, ordinal)` index is built `CONCURRENTLY`;
    an invalid leftover from an interrupted build is dropped first.
  - NOT NULL is established through a `NOT VALID` check constraint that is
    then validated (a scan under a lock that does not block writes), so
    `SET NOT NULL` can rely on it instead of scanning under an exclusive lock.

  Every step is idempotent, so a retry after an interruption resumes where the
  previous attempt stopped and a re-run on a finished table changes nothing.
  The loader does not depend on this job finishing: until it does, a run
  numbers an unnumbered row it writes and withdraws an unnumbered current row
  it did not observe.

  Enqueued once by the migration that adds the column
  (`20261018140000_add_ordinal_to_vulnerability_advisories`).
  To re-run by hand: `%{} |> OrdinalBackfillWorker.new() |> Oban.insert()`.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 10,
    unique: [period: :infinity, states: :incomplete]

  alias ServiceRadar.Repo

  require Logger

  @batch_size 5_000
  @statement_timeout_ms 600_000
  @index "vulnerability_advisories_feed_ordinal_uidx"
  @check "vulnerability_advisories_ordinal_not_null"

  # Keyset by primary key over the rows still unnumbered: each batch reads the
  # next id range through the primary key index, and a resumed run skips rows
  # an earlier attempt already numbered.
  @number_batch_sql """
  WITH batch AS (
    SELECT id
    FROM platform.vulnerability_advisories
    WHERE id > $1 AND ordinal IS NULL
    ORDER BY id
    LIMIT $2
  ), numbered AS (
    UPDATE platform.vulnerability_advisories AS advisory
    SET ordinal = nextval('platform.vulnerability_advisories_ordinal_seq')
    FROM batch
    WHERE advisory.id = batch.id AND advisory.ordinal IS NULL
    RETURNING 1
  )
  SELECT (SELECT id FROM batch ORDER BY id DESC LIMIT 1),
         (SELECT count(*) FROM batch),
         (SELECT count(*) FROM numbered)
  """

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    numbered = number_rows(<<0::128>>, 0)
    create_unique_index()
    set_not_null()

    Logger.info("Advisory ordinal backfill complete", rows_numbered: numbered)
    :ok
  end

  defp number_rows(after_id, total) do
    %{rows: [[last_id, scanned, numbered]]} =
      query!(@number_batch_sql, [after_id, @batch_size])

    total = total + numbered

    if scanned >= @batch_size do
      Logger.info("Advisory ordinal backfill progress", rows_numbered: total)
      number_rows(last_id, total)
    else
      total
    end
  end

  defp create_unique_index do
    %{rows: invalid} =
      query!(
        """
        SELECT 1
        FROM pg_index
        JOIN pg_class ON pg_class.oid = pg_index.indexrelid
        JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
        WHERE pg_namespace.nspname = 'platform'
          AND pg_class.relname = $1
          AND NOT pg_index.indisvalid
        """,
        [@index]
      )

    if invalid != [], do: query!("DROP INDEX CONCURRENTLY IF EXISTS platform.#{@index}")

    query!("""
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS #{@index}
      ON platform.vulnerability_advisories (provider, feed_key, ordinal)
      INCLUDE (current)
    """)
  end

  defp set_not_null do
    query!("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = '#{@check}'
          AND conrelid = 'platform.vulnerability_advisories'::regclass
      ) THEN
        ALTER TABLE platform.vulnerability_advisories
          ADD CONSTRAINT #{@check} CHECK (ordinal IS NOT NULL) NOT VALID;
      END IF;
    END
    $$
    """)

    query!("ALTER TABLE platform.vulnerability_advisories VALIDATE CONSTRAINT #{@check}")
    query!("ALTER TABLE platform.vulnerability_advisories ALTER COLUMN ordinal SET NOT NULL")
    query!("ALTER TABLE platform.vulnerability_advisories DROP CONSTRAINT IF EXISTS #{@check}")
  end

  defp query!(sql, params \\ []), do: Repo.query!(sql, params, timeout: @statement_timeout_ms)
end
