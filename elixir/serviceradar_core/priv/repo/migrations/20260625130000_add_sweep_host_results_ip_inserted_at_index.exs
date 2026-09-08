defmodule ServiceRadar.Repo.Migrations.AddSweepHostResultsIpInsertedAtIndex do
  @moduledoc """
  Add a composite `(ip, inserted_at DESC)` index so the device-detail discovery
  panel's "latest sweep results for this IP" query is served from one index range
  scan instead of walking the inserted_at-only index.

  The query (Ash `:by_ip` + load `:execution`, discovery_data.ex:157-167) is:

      SELECT ... FROM platform.sweep_host_results
      WHERE ip = $1 ORDER BY inserted_at DESC LIMIT 10

  With only `sweep_host_results_ip_idx (ip)` and
  `sweep_host_results_inserted_at_idx (inserted_at)` present, the planner picks
  the inserted_at index for the ORDER BY and applies `ip` as a heap Filter — an
  Index Scan BACKWARD that, for an IP with few/no recent rows, walks deep into the
  2.8M-row / ~495MB table (~133ms; live worst-case cost ~337k). The ip-anchored
  bitmap plan is only ~8k but isn't chosen because no single index satisfies both
  the equality and the ordered LIMIT.

  A composite `(ip, inserted_at DESC)` satisfies `WHERE ip = $1 ORDER BY
  inserted_at DESC LIMIT 10` from a single index range scan, so the planner
  prefers it over the inserted_at-only backward scan.

  Built `CONCURRENTLY` + `IF NOT EXISTS`; purely additive, results unchanged.
  A VACUUM / pg_repack to clear the ~266k dead tuples is a separate follow-up.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS sweep_host_results_ip_inserted_at_idx
    ON platform.sweep_host_results (ip, inserted_at DESC)
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS platform.sweep_host_results_ip_inserted_at_idx")
  end
end
