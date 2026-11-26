defmodule ServiceRadar.Repo.Migrations.RebuildInvalidCurrentKevIndex do
  @moduledoc """
  Rebuilds `vulnerability_advisories_current_kev_idx` when it is missing or invalid.

  `20261126013000_index_current_kev_advisories` built the index with
  `CREATE INDEX CONCURRENTLY IF NOT EXISTS`. An interrupted concurrent build leaves an invalid
  index under that name; the migration is then retried, `IF NOT EXISTS` skips the build and
  records it as applied, and CvePriority's current-KEV read keeps scanning the whole advisory
  table. This migration checks the index's state and drops and rebuilds it only when it is not
  valid; a valid index is left alone.

  Built `CONCURRENTLY` in a migration of its own with the DDL transaction and migration lock
  disabled, because advisory feeds rewrite the table while they load.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @index "vulnerability_advisories_current_kev_idx"

  @create """
  CREATE INDEX CONCURRENTLY IF NOT EXISTS vulnerability_advisories_current_kev_idx
  ON platform.vulnerability_advisories (provider, feed_key)
  WHERE current AND kev
  """

  def up do
    case index_state(@index) do
      :valid ->
        :ok

      :invalid ->
        execute("DROP INDEX CONCURRENTLY IF EXISTS platform.#{@index}")
        execute(@create)

      :missing ->
        execute(@create)
    end
  end

  # The index belongs to 20261126013000; rolling this migration back leaves it in place.
  def down, do: :ok

  defp index_state(name) do
    %{rows: rows} =
      repo().query!(
        """
        SELECT COALESCE(i.indisvalid AND i.indisready AND i.indislive, false)
        FROM pg_class AS c
        JOIN pg_namespace AS n ON n.oid = c.relnamespace
        JOIN pg_index AS i ON i.indexrelid = c.oid
        WHERE n.nspname = 'platform' AND c.relname = $1
        """,
        [name]
      )

    case rows do
      [] -> :missing
      [[true]] -> :valid
      [[false]] -> :invalid
    end
  end
end
