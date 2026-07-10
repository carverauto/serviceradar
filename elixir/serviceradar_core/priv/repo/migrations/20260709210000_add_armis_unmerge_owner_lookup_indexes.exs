defmodule ServiceRadar.Repo.Migrations.AddArmisUnmergeOwnerLookupIndexes do
  @moduledoc """
  Indexed normalized-MAC ownership lookups used by the fail-closed Armis
  disposition while its short DML barrier is held. A retry preserves a valid
  same-name index but replaces the invalid index relation PostgreSQL can leave
  behind when `CREATE INDEX CONCURRENTLY` is interrupted.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    ensure_valid_concurrent_index(
      "device_identifiers_mac_tokens_gin_idx",
      """
      CREATE INDEX CONCURRENTLY IF NOT EXISTS device_identifiers_mac_tokens_gin_idx
      ON platform.device_identifiers
      USING GIN ((
        regexp_split_to_array(
          upper(translate(identifier_value, ':-.', '')),
          '[,;[:space:]]+'
        )
      ))
      WHERE identifier_type = 'mac'
      """
    )

    ensure_valid_concurrent_index(
      "ocsf_devices_display_mac_tokens_gin_idx",
      """
      CREATE INDEX CONCURRENTLY IF NOT EXISTS ocsf_devices_display_mac_tokens_gin_idx
      ON platform.ocsf_devices
      USING GIN ((
        regexp_split_to_array(
          upper(translate(mac, ':-.', '')),
          '[,;[:space:]]+'
        )
      ))
      WHERE mac IS NOT NULL
      """
    )
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS platform.ocsf_devices_display_mac_tokens_gin_idx")

    execute("DROP INDEX CONCURRENTLY IF EXISTS platform.device_identifiers_mac_tokens_gin_idx")
  end

  defp ensure_valid_concurrent_index(index_name, create_statement) do
    index_name
    |> concurrent_index_state()
    |> repair_commands(index_name, create_statement)
    |> Enum.each(&execute/1)
  end

  defp concurrent_index_state(index_name) do
    %{rows: rows} =
      repo().query!(
        """
        SELECT c.relkind::text,
               COALESCE(i.indisvalid AND i.indisready AND i.indislive, false)
        FROM pg_class AS c
        JOIN pg_namespace AS n ON n.oid = c.relnamespace
        LEFT JOIN pg_index AS i ON i.indexrelid = c.oid
        WHERE n.nspname = 'platform' AND c.relname = $1
        """,
        [index_name]
      )

    classify_index_rows(rows)
  end

  @doc false
  def classify_index_rows(rows) do
    case rows do
      [] -> :missing
      [["i", true]] -> :valid
      [["i", false]] -> :invalid
      [[relation_kind, _valid]] -> {:unexpected_relation, relation_kind}
    end
  end

  @doc false
  def repair_commands(:missing, _index_name, create_statement), do: [create_statement]
  def repair_commands(:valid, _index_name, _create_statement), do: []

  def repair_commands(:invalid, index_name, create_statement) do
    ["DROP INDEX CONCURRENTLY IF EXISTS platform.#{index_name}", create_statement]
  end

  def repair_commands({:unexpected_relation, relation_kind}, index_name, _create_statement) do
    raise "expected platform.#{index_name} to be an index, got relkind #{relation_kind}"
  end
end
