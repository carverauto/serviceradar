defmodule ServiceRadar.Inventory.AdvisoryFeeds.OrdinalBackfillWorkerIntegrationTest do
  @moduledoc """
  Numbers pre-ordinal advisory rows and constrains the column through the real
  job against CNPG.

  `CREATE INDEX CONCURRENTLY` cannot run in a transaction, so this test is
  unboxed: it inserts uniquely keyed advisory rows and, on exit, deletes them
  and returns `ordinal` to the state the migration leaves it in (nullable, no
  unique index).
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Inventory.AdvisoryFeeds.OrdinalBackfillWorker
  alias ServiceRadar.Repo

  @moduletag :integration
  @moduletag sandbox: :unboxed

  @provider "test-provider"
  @index "vulnerability_advisories_feed_ordinal_uidx"
  @check "vulnerability_advisories_ordinal_not_null"

  setup do
    feed_key = "ordinal-backfill-itest-#{System.unique_integer([:positive])}"
    restore_unbackfilled_column!()

    on_exit(fn ->
      Repo.query!(
        "DELETE FROM platform.vulnerability_advisories WHERE provider = $1 AND feed_key = $2",
        [@provider, feed_key]
      )

      restore_unbackfilled_column!()
    end)

    {:ok, feed_key: feed_key}
  end

  test "resumes an interrupted backfill without renumbering, then is a no-op when re-run",
       %{feed_key: feed_key} do
    for id <- ~w(adv-1 adv-2 adv-3), do: insert_unnumbered!(feed_key, id)

    # An earlier attempt numbered one row and added the NOT VALID check before
    # it was interrupted.
    %{rows: [[resumed_ordinal]]} =
      Repo.query!(
        """
        UPDATE platform.vulnerability_advisories
        SET ordinal = nextval('platform.vulnerability_advisories_ordinal_seq')
        WHERE provider = $1 AND feed_key = $2 AND source_object_id = 'adv-2'
        RETURNING ordinal
        """,
        [@provider, feed_key]
      )

    Repo.query!("""
    ALTER TABLE platform.vulnerability_advisories
      ADD CONSTRAINT #{@check} CHECK (ordinal IS NOT NULL) NOT VALID
    """)

    assert :ok = OrdinalBackfillWorker.perform(%Oban.Job{args: %{}})

    ordinals = ordinals(feed_key)
    assert ordinals |> Map.values() |> Enum.all?(&is_integer/1)
    assert ordinals |> Map.values() |> Enum.uniq() |> length() == 3
    assert ordinals["adv-2"] == resumed_ordinal

    assert column_not_null?()
    assert valid_unique_index?()
    refute check_constraint?()

    assert :ok = OrdinalBackfillWorker.perform(%Oban.Job{args: %{}})
    assert ordinals(feed_key) == ordinals
    assert column_not_null?()
    assert valid_unique_index?()
    refute check_constraint?()
  end

  defp insert_unnumbered!(feed_key, id) do
    Repo.query!(
      """
      INSERT INTO platform.vulnerability_advisories
        (provider, feed_key, source_object_id, advisory_id, ordinal)
      VALUES ($1, $2, $3, $3, NULL)
      """,
      [@provider, feed_key, id]
    )
  end

  defp ordinals(feed_key) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT source_object_id, ordinal
        FROM platform.vulnerability_advisories
        WHERE provider = $1 AND feed_key = $2
        """,
        [@provider, feed_key]
      )

    Map.new(rows, fn [id, ordinal] -> {id, ordinal} end)
  end

  defp column_not_null? do
    %{rows: [[not_null]]} =
      Repo.query!("""
      SELECT attnotnull
      FROM pg_attribute
      WHERE attrelid = 'platform.vulnerability_advisories'::regclass
        AND attname = 'ordinal'
      """)

    not_null
  end

  defp valid_unique_index? do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT pg_index.indisvalid AND pg_index.indisunique
        FROM pg_index
        JOIN pg_class ON pg_class.oid = pg_index.indexrelid
        WHERE pg_index.indrelid = 'platform.vulnerability_advisories'::regclass
          AND pg_class.relname = $1
        """,
        [@index]
      )

    rows == [[true]]
  end

  defp check_constraint? do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT 1 FROM pg_constraint
        WHERE conname = $1 AND conrelid = 'platform.vulnerability_advisories'::regclass
        """,
        [@check]
      )

    rows != []
  end

  defp restore_unbackfilled_column! do
    Repo.query!("DROP INDEX CONCURRENTLY IF EXISTS platform.#{@index}")

    Repo.query!(
      "ALTER TABLE platform.vulnerability_advisories DROP CONSTRAINT IF EXISTS #{@check}"
    )

    Repo.query!(
      "ALTER TABLE platform.vulnerability_advisories ALTER COLUMN ordinal DROP NOT NULL"
    )
  end
end
