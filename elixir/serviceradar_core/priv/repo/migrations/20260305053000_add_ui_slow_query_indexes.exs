defmodule ServiceRadar.Repo.Migrations.AddUiSlowQueryIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    execute(create_index_sql("idx_ocsf_devices_active_last_seen_uid", """
    ON platform.ocsf_devices (last_seen_time DESC, uid ASC)
    WHERE deleted_at IS NULL
    """))

    execute(create_index_sql("idx_discovered_interfaces_device_if_index_time", """
    ON platform.discovered_interfaces (device_id, if_index, timestamp DESC)
    """))
  end

  def down do
    execute(drop_index_sql("platform.idx_discovered_interfaces_device_if_index_time"))
    execute(drop_index_sql("platform.idx_ocsf_devices_active_last_seen_uid"))
  end

  defp create_index_sql(index_name, definition_sql) do
    "CREATE INDEX #{concurrently_sql()}IF NOT EXISTS #{index_name}\n#{String.trim(definition_sql)}\n"
  end

  defp drop_index_sql(index_name) do
    "DROP INDEX #{concurrently_sql()}IF EXISTS #{index_name}"
  end

  defp concurrently_sql do
    if use_concurrent_indexes?(), do: "CONCURRENTLY ", else: ""
  end

  defp use_concurrent_indexes? do
    case System.get_env("SERVICERADAR_MIGRATION_CONCURRENT_INDEXES") do
      nil -> System.get_env("MIX_ENV") != "test"
      value -> value in ~w(true 1 yes)
    end
  end
end
