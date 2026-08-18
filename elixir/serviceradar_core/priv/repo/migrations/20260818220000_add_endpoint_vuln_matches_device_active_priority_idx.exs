defmodule ServiceRadar.Repo.Migrations.AddEndpointVulnMatchesDeviceActivePriorityIdx do
  @moduledoc """
  Serves Device Software `current_by_device`:

      WHERE device_uid = $1 AND status = 'active'
      ORDER BY kev DESC, exploit_available DESC, cvss_score DESC, last_seen_at DESC
      LIMIT 50

  Postgres was using `endpoint_vulnerability_matches_priority_idx`
  (kev, exploit_available, status) and filtering device_uid after the fact —
  on demo that walked ~74k active rows (~400ms) to paint one host. This
  partial index starts at the device and is already in sort order so LIMIT 50
  can stop early.

  GIN on advisory `raw` / `affected_coordinates` is the matcher path, not this
  list.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @schema "platform"
  @index_name "endpoint_vulnerability_matches_device_active_priority_idx"

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@index_name}
    ON #{@schema}.endpoint_vulnerability_matches (
      device_uid,
      kev DESC,
      exploit_available DESC,
      cvss_score DESC NULLS LAST,
      last_seen_at DESC
    )
    WHERE status = 'active'
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS #{@schema}.#{@index_name}")
  end
end
