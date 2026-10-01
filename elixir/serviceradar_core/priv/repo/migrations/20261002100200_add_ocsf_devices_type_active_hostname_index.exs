defmodule ServiceRadar.Repo.Migrations.AddOcsfDevicesTypeActiveHostnameIndex do
  @moduledoc """
  Serves SRQL queries that filter by device type and active status and sort by
  hostname: `in:devices type:"IP Camera" is_active:true sort:hostname:asc`.

  The SRQL engine emits two expression predicates that a plain column index
  cannot match:

    * type filter  – `COALESCE(NULLIF(trim(type), ''), 'Unknown') = $1`
    * active filter – `COALESCE(is_active, true) = true` (default and explicit)

  The index therefore uses an expression key on the type column and a partial-
  index WHERE clause that exactly mirrors the active and soft-delete predicates,
  leaving hostname and uid as the sort/tie-break keys:

    CREATE INDEX CONCURRENTLY … ON platform.ocsf_devices
      ((COALESCE(NULLIF(trim(type), ''), 'Unknown')), hostname, uid)
    WHERE COALESCE(is_active, true) = true AND deleted_at IS NULL

  With this shape the planner can satisfy the type equality, hostname ordering,
  and uid tie-break from the index alone without a separate sort pass.

  Built `CONCURRENTLY` to avoid blocking writes; that cannot run inside a
  transaction, hence the DDL transaction and migration lock are disabled.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @index "ocsf_devices_type_active_hostname_idx"

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@index}
    ON platform.ocsf_devices (
      (COALESCE(NULLIF(trim(type), ''), 'Unknown')),
      hostname,
      uid
    )
    WHERE COALESCE(is_active, true) = true
      AND deleted_at IS NULL
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS platform.#{@index}")
  end
end
