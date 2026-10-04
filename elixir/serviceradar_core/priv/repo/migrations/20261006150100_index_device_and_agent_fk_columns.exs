defmodule ServiceRadar.Repo.Migrations.IndexDeviceAndAgentFkColumns do
  @moduledoc """
  Indexes the unindexed foreign-key columns that point at `ocsf_devices.uid`
  (`alerts.device_uid`, `service_checks.device_uid`), `ocsf_agents.uid`
  (`alerts.agent_uid`, `service_checks.agent_uid`, `checkers.agent_uid`) and
  `service_checks.id` (`alerts.service_check_id`).

  The device retention purge deletes a batch of devices together with their
  agents and service checks. With these columns unindexed, both its child
  deletes and the foreign-key check Postgres runs for every deleted parent row
  scanned each whole table -- once per device, agent or service check in the
  batch, inside one transaction.

  Partial on `<col> IS NOT NULL`: only referencing rows need to be found.
  Built `CONCURRENTLY` so writers are not blocked; that cannot run inside a
  transaction, hence the DDL transaction and migration lock are disabled.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @indexes [
    {"alerts", "device_uid"},
    {"service_checks", "device_uid"},
    {"alerts", "agent_uid"},
    {"service_checks", "agent_uid"},
    {"checkers", "agent_uid"},
    {"alerts", "service_check_id"}
  ]

  def up do
    for {table, column} <- @indexes do
      execute("""
      CREATE INDEX CONCURRENTLY IF NOT EXISTS #{table}_#{column}_fk_idx
      ON platform.#{table} (#{column})
      WHERE #{column} IS NOT NULL
      """)
    end
  end

  def down do
    for {table, column} <- @indexes do
      execute("DROP INDEX CONCURRENTLY IF EXISTS platform.#{table}_#{column}_fk_idx")
    end
  end
end
