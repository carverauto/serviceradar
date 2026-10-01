defmodule ServiceRadar.Repo.Migrations.AddOcsfDevicesTypeActiveHostnameIndex do
  @moduledoc """
  Serves SRQL queries that filter by device type and active status and sort by
  hostname: `in:devices type:"IP Cameras" is_active:true sort:hostname:asc`.

  The index matches SRQL's normalized type and active predicates and provides
  ascending hostname order with the UID tie-breaker. This lets the planner use
  an ordered index scan for matching queries instead of a separate sort.

  Built `CONCURRENTLY` to avoid blocking writes; that cannot run inside a
  transaction, hence the DDL transaction and migration lock are disabled.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @index_columns [
    "(COALESCE(NULLIF(trim(type), ''), 'Unknown'))",
    "(COALESCE(is_active, true))",
    :hostname,
    :uid
  ]

  def up do
    create_if_not_exists(
      index(:ocsf_devices, @index_columns,
        prefix: "platform",
        name: "ocsf_devices_type_active_hostname_idx",
        concurrently: true,
        where: "deleted_at IS NULL"
      )
    )
  end

  def down do
    drop_if_exists(
      index(:ocsf_devices, @index_columns,
        prefix: "platform",
        name: "ocsf_devices_type_active_hostname_idx",
        concurrently: true
      )
    )
  end
end
