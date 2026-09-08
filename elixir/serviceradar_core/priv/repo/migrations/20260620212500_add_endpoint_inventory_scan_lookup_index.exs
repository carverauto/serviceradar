defmodule ServiceRadar.Repo.Migrations.AddEndpointInventoryScanLookupIndex do
  @moduledoc """
  Index-serves endpoint inventory's agent-scoped device fallback lookup.

  `EndpointInventoryIngestor.build_context/5` falls back to the latest non-null
  `device_uid` seen for an agent when the live agent record is missing a
  canonical device. Under ingest bursts this lookup is on the synchronous
  endpoint-inventory path; without an order-matching partial index Postgres can
  scan/sort an agent's scan history before every upload.

  The predicate and ordering mirror `existing_scan_device_uid/1`. The included
  `device_uid` lets Postgres satisfy the lookup from the index when visibility
  permits, while keeping the index restricted to scans that can answer the
  fallback.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @schema "platform"
  @index_name "endpoint_inventory_scans_agent_latest_device_idx"

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@index_name}
    ON #{@schema}.endpoint_inventory_scans (
      agent_id,
      last_scan_at DESC NULLS LAST,
      inserted_at DESC
    )
    INCLUDE (device_uid)
    WHERE device_uid IS NOT NULL
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS #{@schema}.#{@index_name}")
  end
end
