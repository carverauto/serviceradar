defmodule ServiceRadar.Repo.Migrations.AddOcsfDevicesTypeActiveHostnameIndex do
  @moduledoc """
  Serves SRQL queries that filter by device type and active status and sort by
  hostname: `in:devices type:"IP Cameras" is_active:true sort:hostname:asc`.

  Without this index those queries do a full sequential scan of `ocsf_devices`
  and a separate sort pass. The composite index covers the WHERE clause and
  provides hostname order directly, avoiding both.

  Built `CONCURRENTLY` to avoid blocking writes; that cannot run inside a
  transaction, hence the DDL transaction and migration lock are disabled.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create_if_not_exists(
      index(:ocsf_devices, [:type, :is_active, :hostname],
        prefix: "platform",
        name: "ocsf_devices_type_active_hostname_idx",
        concurrently: true,
        where: "deleted_at IS NULL"
      )
    )
  end

  def down do
    drop_if_exists(
      index(:ocsf_devices, [:type, :is_active, :hostname],
        prefix: "platform",
        name: "ocsf_devices_type_active_hostname_idx",
        concurrently: true
      )
    )
  end
end
